#!/usr/bin/env python3
"""
Minimal SystemVerilog → C++ filter for Doxygen.

Transforms SV module declarations and doc-comment annotations to C++
equivalents so that Doxygen can extract port, parameter, and module-level
documentation from .sv files.

Usage (via Doxyfile):
    FILTER_PATTERNS = *.sv=scripts/doxygen_sv_filter.py
    EXTENSION_MAPPING = sv=C++

Only the comment structure and top-level declarations are translated;
the rest of the RTL body is commented out so the C++ parser ignores it
without emitting errors.
"""

import sys
import re

def transform(content: str) -> str:
    lines = content.splitlines()
    out = []
    inside_body = False   # True once we're past the port-list closing ')'
    paren_depth = 0
    module_seen = False

    for line in lines:
        stripped = line.strip()

        # ─── Pass through Doxygen block comments verbatim ──────────────────
        if stripped.startswith('/**') or stripped.startswith('/*!') or \
                stripped.startswith('*') or stripped.startswith('*/') or \
                stripped.startswith('//!') or stripped.startswith('///'):
            out.append(line)
            continue

        # ─── module declaration ─────────────────────────────────────────────
        #  module foo_bar #( ... ) ( ... );  →  class foo_bar {
        if re.match(r'\s*module\s+\w+', line):
            module_seen = True
            inside_body = False
            paren_depth = 0
            name = re.search(r'module\s+(\w+)', line).group(1)
            out.append(f'class {name}')
            out.append('{')
            out.append('public:')
            # count parens on this line
            paren_depth += line.count('(') - line.count(')')
            if paren_depth <= 0 and ';' in line:
                inside_body = True
            continue

        # ─── endmodule ─────────────────────────────────────────────────────
        if re.match(r'\s*endmodule\b', line):
            out.append('};')
            inside_body = False
            module_seen = False
            continue

        if not module_seen:
            # Before any module: pass through (e.g. package imports, comments)
            out.append(line)
            continue

        # ─── Inside the module header (parameter + port list) ──────────────
        if not inside_body:
            paren_depth += line.count('(') - line.count(')')
            if paren_depth <= 0:
                inside_body = True

            # parameter → int type name = default;  (simplified for Doxygen)
            pline = line
            pline = re.sub(r'\bparameter\s+', 'int ', pline)
            pline = re.sub(r'\blocalparam\s+', 'static const int ', pline)

            # Strip SV type qualifiers (leave name + default value)
            for kw in ['logic', 'wire', 'reg', 'bit', 'int unsigned',
                       'int signed', 'int', 'signed', 'unsigned']:
                pline = re.sub(r'\b' + re.escape(kw) + r'\b', '', pline)

            # input/output/inout → member type (simplified)
            pline = re.sub(r'\b(input|output|inout)\s*', 'int ', pline)

            # Strip packed dimensions e.g. [31:0]
            pline = re.sub(r'\[[\w:+\-*/ ]+\]', '', pline)

            # Strip `ifdef / `ifndef / `endif macros
            pline = re.sub(r'`\w+.*', '', pline)

            out.append(pline)
            continue

        # ─── Body: replace with a single-line comment so C++ parser skips ──
        # But preserve any doc-comments that the RTL author added
        if stripped.startswith('//'):
            out.append(line)
        else:
            out.append('// ' + stripped if stripped else '')

    return '\n'.join(out)

if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit('Usage: doxygen_sv_filter.py <file.sv>')
    with open(sys.argv[1], encoding='utf-8', errors='replace') as fh:
        content = fh.read()
    print(transform(content))
