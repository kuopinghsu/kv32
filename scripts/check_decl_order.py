#!/usr/bin/env python3
"""
check_decl_order.py — Detect signals used before their declaration line.

Synthesis tools (DC, Genus, Vivado in strict mode) sometimes reject forward
references inside a module even though SV allows them.  This script flags any
signal whose first *use* line is earlier than its *declaration* line.

Usage:
    python3 check_decl_order.py <file1.sv> [file2.sv ...]
    Exit 0 = clean, Exit 1 = violations found.
"""

import re
import sys
import os

# ── Tokens that introduce a variable declaration ────────────────────────────
# Captures optional signing/width so we can skip them and hit the name.
DECL_KW = re.compile(
    r'\b(input|output|inout|wire|reg|logic|bit|byte|shortint|int|longint'
    r'|integer|time|real|realtime|event|tri|tri0|tri1|trireg|var)\b',
    re.ASCII
)

# Identifier pattern — plain alphanumeric + underscore, not starting with digit
IDENT = re.compile(r'\b([A-Za-z_][A-Za-z0-9_$]*)\b')

# Keywords that are NOT signal identifiers
SV_KEYWORDS = frozenset("""
    module endmodule package endpackage interface endinterface program endprogram
    class endclass function endfunction task endtask always always_ff always_comb
    always_latch initial final begin end if else case casez casex endcase for
    foreach while repeat forever do break continue return
    input output inout wire reg logic bit byte shortint int longint integer
    time real realtime event tri tri0 tri1 trireg var signed unsigned
    posedge negedge or and not buf
    assign force release deassign default parameter localparam defparam
    generate endgenerate genvar
    import export typedef enum struct union packed
    virtual automatic static protected local
    null this super new
    unique priority
    fork join join_any join_none
    wait disable fork
    property sequence assert assume cover restrict
    clocking endclocking modport
    specify endspecify timeprecision timeunit
    inside dist with
    tagged void
    string chandle
    $bits $clog2 $signed $unsigned $size $high $low $left $right
    $display $write $monitor $strobe $fopen $fclose $fwrite $fdisplay
    $finish $stop $error $warning $info $fatal
    $random $urandom $urandom_range
    $time $realtime $stime
    $rose $fell $stable $changed $past $future $sampled
    $isunknown $countones $onehot $onehot0
    $readmemh $readmemb $writememh $writememb
    FAST_MUL FAST_DIV ICACHE_EN ICACHE_SIZE ICACHE_LINE_SIZE ICACHE_WAYS
    MEM_READ_LATENCY MEM_WRITE_LATENCY MEM_DUAL_PORT
""".split())

def strip_comments_and_strings(line: str) -> str:
    """Remove // line comments and string literals from a line."""
    # Remove string literals
    line = re.sub(r'"[^"]*"', '""', line)
    # Remove // comments
    idx = line.find('//')
    if idx >= 0:
        line = line[:idx]
    return line

def prepare_for_decl_scan(line: str) -> str:
    """
    Prepare a line for declaration scanning by removing constructs that
    would cause false positives:
      - System tasks/functions like $time, $display → removed so 'time' isn't
        matched as the 'time' type keyword
      - Type casts like int'(...), logic'(...) → the type name is removed so it
        isn't treated as a declaration keyword
      - Non-blocking / relational assignment operators (<=, >=, ==, !=)
        are neutralised so we can split at '=' to get the LHS only
      - Bit literals like 1'b0, 8'hFF → removed so 'b0', 'hFF', etc. are not
        extracted as identifiers
    Returns a string suitable for extracting declared names only.
    """
    s = line
    # Strip system tasks/functions: $word
    s = re.sub(r'\$\w+', '', s)
    # Strip bit literals: <digits>'<radix_char><digits/letters>
    s = re.sub(r"\d+\s*'[shbodSHBOD][0-9xzXZa-fA-F_]*", '', s)
    # Strip type casts: word'( → remove the word so 'int'(' becomes '('
    s = re.sub(r"\b\w+\s*'(?=\s*\()", '', s)
    # Neutralise compound operators so they aren't split as '='
    s = s.replace('<=', '##').replace('>=', '##').replace('==', '##').replace('!=', '##')
    # Now split at the first bare '=' and take only the LHS; this stops
    # RHS initialiser expressions from polluting the declared-name set.
    s = s.split('=')[0]
    return s

def parse_module_ports(header_lines: list) -> set:
    """
    Extract port names AND parameter names from the ANSI module header
    (between 'module name (' and the first ');').
    These count as declared at line 0 (module header).
    """
    ports = set()
    combined = ' '.join(header_lines)
    # Extract parameter names from #(...)
    m_params = re.search(r'#\s*\((.*?)\)', combined, re.DOTALL)
    if m_params:
        param_body = m_params.group(1)
        for tok in IDENT.finditer(param_body):
            name = tok.group(1)
            if name not in SV_KEYWORDS:
                ports.add(name)
    # Strip parameter list to get port-only body
    combined_no_params = re.sub(r'#\s*\(.*?\)', '', combined, flags=re.DOTALL)
    m = re.search(r'\((.*?)\)', combined_no_params, re.DOTALL)
    if not m:
        return ports
    port_body = m.group(1)
    # Each port declaration: optional direction/type, then identifier
    for token in IDENT.finditer(port_body):
        name = token.group(1)
        if name not in SV_KEYWORDS:
            ports.add(name)
    return ports

def check_file(path: str) -> list:
    """
    Returns a list of (line_no, signal, decl_line) tuples for violations.
    """
    try:
        with open(path) as f:
            raw_lines = f.readlines()
    except OSError as e:
        print(f'ERROR: cannot open {path}: {e}', file=sys.stderr)
        return []

    lines = [strip_comments_and_strings(l) for l in raw_lines]
    violations = []

    # ── State machine: find module boundaries ───────────────────────────────
    i = 0
    n = len(lines)

    while i < n:
        # Look for 'module <name>' or 'package <name>'
        stripped = lines[i].strip()
        if not re.match(r'\b(module|package)\b', stripped):
            i += 1
            continue

        mod_start = i

        # Collect the header (up to the first ';')
        header_lines = []
        j = i
        while j < n:
            header_lines.append(lines[j])
            if ';' in lines[j]:
                break
            j += 1
        header_end = j + 1     # first line of module body

        # Parse port names from the header — declare at line 0
        port_names = parse_module_ports(header_lines)

        # ── Walk module body ─────────────────────────────────────────────────
        # decl_map: signal_name → first declaration line (1-based)
        decl_map: dict[str, int] = {}
        # use_map:  signal_name → first use line (1-based)
        use_map:  dict[str, int] = {}

        # Track `define / localparam names so we don't flag them
        const_names: set[str] = set()

        depth = 1           # begin/end depth relative to module
        k = header_end

        while k < n:
            raw = raw_lines[k]
            clean = lines[k]
            k1 = k + 1       # 1-based line number

            # ── Track endmodule / endpackage ─────────────────────────────
            if re.search(r'\b(endmodule|endpackage)\b', clean):
                break

            # ── Detect declarations ──────────────────────────────────────
            if DECL_KW.search(clean):
                # Use the sanitised LHS-only string to extract declared names.
                # This avoids false positives from:
                #   - type casts like int'(expr)
                #   - bit literals like 1'b0 → 'b0' identifier
                #   - RHS initialiser expressions (wire foo = expr)
                decl_scan_str = prepare_for_decl_scan(clean)
                # Strip array dimensions to avoid false positives from ranges
                decl_scan_str = re.sub(r'\[.*?\]', '', decl_scan_str)
                in_decl = False
                for tok in IDENT.finditer(decl_scan_str):
                    name = tok.group(1)
                    if name in SV_KEYWORDS:
                        if DECL_KW.match(name):
                            in_decl = True
                        continue
                    if in_decl:
                        if name not in decl_map and name not in port_names:
                            decl_map[name] = k1
                        # Allow multiple names on the same decl line
                        # (in_decl stays True until ';')
                if ';' in clean:
                    pass     # in_decl naturally resets per-line

            # ── Detect localparam / parameter names ─────────────────────
            if re.search(r'\b(localparam|parameter)\b', clean):
                # Use the sanitised LHS-only string to avoid RHS false positives
                const_scan_str = prepare_for_decl_scan(clean)
                const_scan_str = re.sub(r'\[.*?\]', '', const_scan_str)
                for tok in IDENT.finditer(const_scan_str):
                    name = tok.group(1)
                    if name not in SV_KEYWORDS:
                        const_names.add(name)
                        if name not in decl_map:
                            decl_map[name] = k1  # treat as declared here

            # ── Detect `define macro names ──────────────────────────────
            m_def = re.match(r'\s*`define\s+(\w+)', raw_lines[k])
            if m_def:
                const_names.add(m_def.group(1))

            # ── Record uses ──────────────────────────────────────────────
            # Strip system tasks/functions before scanning to avoid false
            # positives like 'time' extracted from '$time'.
            clean_for_uses = re.sub(r'\$\w+', '', clean)
            for tok in IDENT.finditer(clean_for_uses):
                name = tok.group(1)
                if name in SV_KEYWORDS:
                    continue
                if name in port_names:
                    continue
                if name not in use_map:
                    use_map[name] = k1

            k += 1

        # ── Compare first-use vs declaration ────────────────────────────────
        for name, use_line in use_map.items():
            if name not in decl_map:
                continue     # not a locally declared signal
            decl_line = decl_map[name]
            if use_line < decl_line:
                violations.append((path, use_line, name, decl_line))

        i = header_end

    return violations

def main():
    import argparse
    ap = argparse.ArgumentParser(description='Check SV signal declaration order')
    ap.add_argument('files', nargs='+', help='SystemVerilog source files to check')
    ap.add_argument('--quiet', '-q', action='store_true',
                    help='Only print violations, not per-file OK messages')
    args = ap.parse_args()

    total_violations = 0
    for path in args.files:
        viols = check_file(path)
        if viols:
            for (f, use_ln, name, decl_ln) in sorted(viols):
                print(f'{f}:{use_ln}: signal \'{name}\' used before declaration '
                      f'(declared at line {decl_ln})')
            total_violations += len(viols)
        elif not args.quiet:
            print(f'OK: {os.path.basename(path)}')

    if total_violations:
        print(f'\n{total_violations} declaration-order violation(s) found.')
        sys.exit(1)
    elif not args.quiet:
        print('\nAll files clean.')
    sys.exit(0)

if __name__ == '__main__':
    main()
