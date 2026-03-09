#!/usr/bin/env python3
"""
Trace Comparison Tool
Compares execution traces from RTL, Spike, and kv32sim with all combinations
Supports:
  - RTL vs Spike
  - RTL vs kv32sim
  - Spike vs kv32sim
  - RTL vs Spike vs kv32sim (three-way comparison)

Comparison features:
  - PC (Program Counter) and instruction matching
  - Register write value comparison
  - Memory access (read/write) address and data comparison
  - CSR (Control and Status Register) access comparison

CSR instruction format differences (spike vs kv32sim):
  For CSR read-modify-write instructions (csrrw/csrrs/csrrc/csrrwi/csrrsi/csrrci)
  the two simulators log different committed writes from the same instruction:
    spike --log-commits: logs the RD write  (rd  <- old_CSR_value)
    kv32sim --rtl-trace: logs the CSR write (csr <- rs1_value)
  These are both correct but describe different sides of the instruction.
  trace_compare.py detects this cross-format case and skips the value
  comparison rather than reporting spurious mismatches.
"""

import sys
import re
import argparse

# ── Module-level constants for fast opcode checks ─────────────────────────────
_CYCLE_CSRS    = frozenset({0xc00, 0xc01, 0xc02, 0xc80, 0xc81, 0xc82,
                             0xb00, 0xb02, 0xb80, 0xb82})
_CSR_RW_FUNCT3 = frozenset({1, 2, 3, 5, 6, 7})

# ── Pre-compiled regex patterns ──────────────────────────────────────────────
# RTL trace line — captured groups:
#   1=cycle  2=pc  3=instr
#   4=regname (opt)  5=regval (opt)
#   6=memaddr (opt)  7=memval (opt)
_RTL_LINE_RE = re.compile(
    r'^(\d+)'
    r'\s+0x([0-9a-fA-F]+)'
    r'\s+\(0x([0-9a-fA-F]+)\)'
    r'(?:\s+(?!mem\b|store\b)([a-zA-Z]\w*)\s+0x([0-9a-fA-F]+))?'
    r'(?:\s+mem\s+0x([0-9a-fA-F]+)(?:\s+0x([0-9a-fA-F]+))?)?'
)

# Spike/kv32sim trace line (both count-prefix and plain variants) — groups:
#   1=pc  2=instr
#   3=regname (opt)  4=regval (opt)
#   5=memaddr (opt)  6=memval (opt)
_SPIKE_LINE_RE = re.compile(
    r'^core\s+\d+:\s+'
    r'(?:\d+\s+)?'
    r'0x([0-9a-fA-F]+)'
    r'\s+\(0x([0-9a-fA-F]+)\)'
    r'(?:\s+(?!mem\b|store\b)([a-zA-Z]\w*)\s+0x([0-9a-fA-F]+))?'
    r'(?:\s+mem\s+0x([0-9a-fA-F]+)(?:\s+0x([0-9a-fA-F]+))?)?'
)

# Format detection
_DETECT_RTL_RE   = re.compile(r'^\d+\s+0x[0-9a-fA-F]+\s+\(0x[0-9a-fA-F]+\)')
_DETECT_SPIKE_RE = re.compile(r'^core\s+\d+:')

# CSR field pattern (rare — only searched when 'csr' appears in the line)
_CSR_FIELD_RE = re.compile(r'csr:?(\w+)\s+0x([0-9a-fA-F]+)')

# RISC-V register number to ABI name mapping
REG_ABI_NAMES = {
    'x0': 'zero', 'x1': 'ra', 'x2': 'sp', 'x3': 'gp',
    'x4': 'tp', 'x5': 't0', 'x6': 't1', 'x7': 't2',
    'x8': 's0', 'x9': 's1', 'x10': 'a0', 'x11': 'a1',
    'x12': 'a2', 'x13': 'a3', 'x14': 'a4', 'x15': 'a5',
    'x16': 'a6', 'x17': 'a7', 'x18': 's2', 'x19': 's3',
    'x20': 's4', 'x21': 's5', 'x22': 's6', 'x23': 's7',
    'x24': 's8', 'x25': 's9', 'x26': 's10', 'x27': 's11',
    'x28': 't3', 'x29': 't4', 'x30': 't5', 'x31': 't6'
}

def normalize_csr_name(csr_name):
    """
    Normalize CSR name by extracting just the name part.
    CSR names can be in format "c<addr>_<name>" where addr is hex (RTL) or decimal (Spike).
    E.g., "c300_mstatus" (RTL hex) and "c768_mstatus" (Spike decimal) both refer to mstatus.
    Returns just the name part (e.g., "mstatus") or the original if no underscore found.
    """
    if '_' in csr_name:
        return csr_name.split('_', 1)[1]
    return csr_name

# Pattern that matches kv32sim/RTL CSR register names: c<hex_digits>_<name>
# e.g. c300_mstatus, c340_mscratch, c305_mtvec
_CSR_NAME_RE = re.compile(r'^c[0-9a-fA-F]+_')  # already pre-compiled

def is_csr_name(reg_name):
    """
    Returns True if reg_name is a CSR-format name used by kv32sim RTL traces.
    CSR names look like: c300_mstatus, c340_mscratch, c305_mtvec.
    Standard ABI register names (s0, t1, sp, a0, …) return False.
    """
    return bool(_CSR_NAME_RE.match(reg_name))

def is_csr_rw_instr(instr_val):
    """
    Returns True for CSR read-modify-write instructions:
      csrrw / csrrs / csrrc  (funct3 = 1/2/3)
      csrrwi / csrrsi / csrrci (funct3 = 5/6/7)
    These are the instructions where spike reports the rd write and
    kv32sim RTL reports the CSR write, causing a cross-format difference.
    """
    opcode = instr_val & 0x7f
    if opcode != 0x73:          # Not a SYSTEM instruction
        return False
    funct3 = (instr_val >> 12) & 0x7
    return funct3 in {1, 2, 3, 5, 6, 7}

def is_amo_instr(instr_val):
    """
    Returns True for RV32A atomic memory-operation instructions (opcode 0x2F).
    AMO instructions perform an atomic read-modify-write.  Spike logs the
    memory read value (REF mem: ...) but kv32sim RTL trace does not emit a
    mem field for AMO, so the mem_access fields will never match in a
    spike vs kv32sim comparison.
    """
    return (instr_val & 0x7f) == 0x2f

def get_store_data_mask(instr_val):
    """
    Return the data mask for a store instruction based on funct3:
      sb  (funct3=0): 0x000000FF  – stores the low byte
      sh  (funct3=1): 0x0000FFFF  – stores the low halfword
      sw  (funct3=2): 0xFFFFFFFF  – stores the full word
    Spike masks the logged mem data to the store width; kv32sim logs the
    full 32-bit register value.  Applying this mask to both sides before
    comparison eliminates the spurious mismatch.
    Returns 0xFFFFFFFF for non-store instructions.
    """
    if (instr_val & 0x7f) != 0x23:   # Not a STORE instruction
        return 0xFFFFFFFF
    funct3 = (instr_val >> 12) & 0x7
    if funct3 == 0:   # sb
        return 0x000000FF
    elif funct3 == 1:  # sh
        return 0x0000FFFF
    else:              # sw
        return 0xFFFFFFFF

def is_cycle_counter_csr(instr_val):
    """Check if instruction is a CSR read from cycle counter (cycle/time/instret and their high halves)"""
    opcode = instr_val & 0x7f
    if opcode != 0x73:  # Not a SYSTEM instruction
        return False

    funct3 = (instr_val >> 12) & 0x7
    if funct3 == 0:  # Not a CSR instruction (ecall/ebreak/mret)
        return False

    csr_addr = (instr_val >> 20) & 0xfff
    # Cycle counters: cycle(0xc00), time(0xc01), instret(0xc02), cycleh(0xc80), timeh(0xc81), instreth(0xc82)
    # Also machine-mode: mcycle(0xb00), minstret(0xb02), mcycleh(0xb80), minstreth(0xb82)
    cycle_csrs = {0xc00, 0xc01, 0xc02, 0xc80, 0xc81, 0xc82, 0xb00, 0xb02, 0xb80, 0xb82}
    return csr_addr in cycle_csrs

def parse_rtl_trace(filename):
    """Parse RTL trace file (format: CYCLES PC (INSTR) ...)"""
    traces = []
    with open(filename, 'r', buffering=1 << 20) as f:
        for line in f:
            m = _RTL_LINE_RE.match(line)
            if not m:
                continue
            cycle_s, pc_s, instr_s, reg_name, reg_val_s, mem_addr_s, mem_val_s = m.groups()

            instr_val = int(instr_s, 16)
            opcode    = instr_val & 0x7f

            # Inline opcode-flag computation (avoids 3 function-call overheads)
            is_load  = opcode == 0x03
            is_store = opcode == 0x23
            is_amo   = opcode == 0x2f
            if opcode == 0x73:  # SYSTEM
                funct3        = (instr_val >> 12) & 0x7
                csr_addr_bits = (instr_val >> 20) & 0xfff
                is_cycle_csr  = funct3 != 0 and csr_addr_bits in _CYCLE_CSRS
                is_csr_rw     = funct3 in _CSR_RW_FUNCT3
            else:
                is_cycle_csr = False
                is_csr_rw    = False

            # reg_write — captured by the combined regex
            reg_write = (reg_name, int(reg_val_s, 16)) if reg_name is not None else None

            # mem_access — captured by the combined regex
            if mem_addr_s is not None:
                addr = int(mem_addr_s, 16)
                val  = int(mem_val_s, 16) if mem_val_s is not None else 0
                mem_access = (addr, val,
                              'write' if is_store else 'read' if is_load else 'unknown')
            else:
                mem_access = None

            # disasm — cheap string find instead of regex
            semi   = line.find('; ')
            disasm = line[semi + 2:].rstrip() if semi != -1 else None

            # csr_access — only pay for the search when 'csr' is present
            csr_access = None
            if 'csr' in line:
                cm = _CSR_FIELD_RE.search(line)
                if cm:
                    csr_access = (cm.group(1), int(cm.group(2), 16), 'access')

            traces.append({
                'cycle':        int(cycle_s),
                'pc':           int(pc_s, 16),
                'instr':        instr_val,
                'opcode':       opcode,
                'is_load':      is_load,
                'is_store':     is_store,
                'is_amo':       is_amo,
                'is_cycle_csr': is_cycle_csr,
                'is_csr_rw':    is_csr_rw,
                'trace_type':   'rtl',
                'line':         line.rstrip(),
                'disasm':       disasm,
                'reg_write':    reg_write,
                'mem_access':   mem_access,
                'csr_access':   csr_access,
            })
    return traces

def parse_spike_trace(filename):
    """Parse Spike/kv32sim trace file (handles both -l and --log-commits formats)."""
    traces = []
    with open(filename, 'r', buffering=1 << 20) as f:
        for line in f:
            m = _SPIKE_LINE_RE.match(line)
            if not m:
                continue
            pc_s, instr_s, reg_name, reg_val_s, mem_addr_s, mem_val_s = m.groups()

            instr_val = int(instr_s, 16)
            opcode    = instr_val & 0x7f

            # Inline opcode-flag computation
            is_load  = opcode == 0x03
            is_store = opcode == 0x23
            is_amo   = opcode == 0x2f
            if opcode == 0x73:  # SYSTEM
                funct3        = (instr_val >> 12) & 0x7
                csr_addr_bits = (instr_val >> 20) & 0xfff
                is_cycle_csr  = funct3 != 0 and csr_addr_bits in _CYCLE_CSRS
                is_csr_rw     = funct3 in _CSR_RW_FUNCT3
            else:
                is_cycle_csr = False
                is_csr_rw    = False

            # reg_write — convert Spike x<N> names to ABI names
            if reg_name is not None:
                if reg_name.startswith('x') and reg_name in REG_ABI_NAMES:
                    reg_name = REG_ABI_NAMES[reg_name]
                reg_write = (reg_name, int(reg_val_s, 16))
            else:
                reg_write = None

            # mem_access
            if mem_addr_s is not None:
                addr = int(mem_addr_s, 16)
                val  = int(mem_val_s, 16) if mem_val_s is not None else 0
                mem_access = (addr, val,
                              'write' if is_store else 'read' if is_load else 'unknown')
            else:
                mem_access = None

            # disasm — cheap string find
            semi   = line.find('; ')
            disasm = line[semi + 2:].rstrip() if semi != -1 else None

            # csr_access — only search when 'csr' is present
            csr_access = None
            if 'csr' in line:
                cm = _CSR_FIELD_RE.search(line)
                if cm:
                    csr_access = (cm.group(1), int(cm.group(2), 16), 'access')

            traces.append({
                'cycle':        None,
                'pc':           int(pc_s, 16),
                'instr':        instr_val,
                'opcode':       opcode,
                'is_load':      is_load,
                'is_store':     is_store,
                'is_amo':       is_amo,
                'is_cycle_csr': is_cycle_csr,
                'is_csr_rw':    is_csr_rw,
                'trace_type':   'spike',
                'line':         line.rstrip(),
                'disasm':       disasm,
                'reg_write':    reg_write,
                'mem_access':   mem_access,
                'csr_access':   csr_access,
            })
    return traces

def detect_trace_type(filename):
    """Detect if this is an RTL trace or Spike/kv32sim trace."""
    with open(filename, 'r', buffering=1 << 20) as f:
        for line in f:
            if not line or line[0] == '#':
                continue
            # RTL format: leading digit(s) then ' 0x...'
            if _DETECT_RTL_RE.match(line):
                return 'rtl'
            # Spike/kv32sim format: starts with 'core'
            if _DETECT_SPIKE_RE.match(line):
                return 'spike'
    return 'unknown'

def normalize_rtl_trace(traces):
    """Remove consecutive duplicate PC/INSTR entries caused by stalls."""
    if not traces:
        return traces
    normalized = [traces[0]]
    for entry in traces[1:]:
        prev = normalized[-1]
        if entry['pc'] == prev['pc'] and entry['instr'] == prev['instr']:
            continue
        normalized.append(entry)
    return normalized

def _parse_rtl_entry(line):
    """
    Full parse of one raw RTL trace line into an entry dict.
    Used by compare_rtl_rtl_streaming for mismatching lines only.
    Returns None if the line does not match the RTL trace format.
    """
    m = _RTL_LINE_RE.match(line)
    if not m:
        return None
    cycle_s, pc_s, instr_s, reg_name, reg_val_s, mem_addr_s, mem_val_s = m.groups()
    instr_val = int(instr_s, 16)
    opcode    = instr_val & 0x7f
    is_load  = opcode == 0x03
    is_store = opcode == 0x23
    is_amo   = opcode == 0x2f
    if opcode == 0x73:
        funct3        = (instr_val >> 12) & 0x7
        csr_addr_bits = (instr_val >> 20) & 0xfff
        is_cycle_csr  = funct3 != 0 and csr_addr_bits in _CYCLE_CSRS
        is_csr_rw     = funct3 in _CSR_RW_FUNCT3
    else:
        is_cycle_csr = False
        is_csr_rw    = False
    reg_write = (reg_name, int(reg_val_s, 16)) if reg_name is not None else None
    if mem_addr_s is not None:
        addr = int(mem_addr_s, 16)
        val  = int(mem_val_s, 16) if mem_val_s is not None else 0
        mem_access = (addr, val,
                      'write' if is_store else 'read' if is_load else 'unknown')
    else:
        mem_access = None
    semi   = line.find('; ')
    disasm = line[semi + 2:].rstrip() if semi != -1 else None
    csr_access = None
    if 'csr' in line:
        cm = _CSR_FIELD_RE.search(line)
        if cm:
            csr_access = (cm.group(1), int(cm.group(2), 16), 'access')
    return {
        'cycle':        int(cycle_s),
        'pc':           int(pc_s, 16),
        'instr':        instr_val,
        'opcode':       opcode,
        'is_load':      is_load,
        'is_store':     is_store,
        'is_amo':       is_amo,
        'is_cycle_csr': is_cycle_csr,
        'is_csr_rw':    is_csr_rw,
        'trace_type':   'rtl',
        'line':         line.rstrip(),
        'disasm':       disasm,
        'reg_write':    reg_write,
        'mem_access':   mem_access,
        'csr_access':   csr_access,
    }

def compare_rtl_rtl_streaming(fname1, fname2):
    """
    Streaming comparison of two RTL-format trace files.

    For the common case where entries match, only two cheap string operations
    are needed per line:
      1. Strip the leading cycle counter  (line.index + slice)
      2. Compare bodies                   (single C-level string equality)
    No regex, no dict, no int parsing for the matching ~99%+ of entries.
    Full parse is deferred to the rare mismatching lines (cycle-CSR value
    differences, or real correctness bugs).

    Consecutive duplicate (PC, INSTR) entries from RTL pipeline stalls are
    collapsed inline (same semantics as normalize_rtl_trace).
    """
    _KEY_LEN = 24  # fixed length of "0x80000000 (0x30401073)"

    def _iter(filename):
        """Yield (body_stripped, raw_line) for each unique RTL trace entry."""
        prev_key = None
        with open(filename, 'r', buffering=4 << 20) as f:
            for line in f:
                fc = line[0] if line else ''
                if fc < '0' or fc > '9':
                    continue
                sp   = line.index(' ')
                off  = sp + 1
                key  = line[off : off + _KEY_LEN]
                if key == prev_key:
                    continue
                prev_key = key
                yield line[off:].rstrip(), line

    print("Detected formats: rtl (REF) vs rtl (TGT)\n")

    iter1 = _iter(fname1)
    iter2 = _iter(fname2)
    mismatches = 0
    entry_num  = 0
    n1 = n2    = 0

    try:
        while True:
            b1, l1 = next(iter1);  n1 += 1
            b2, l2 = next(iter2);  n2 += 1
            entry_num += 1

            # ── Ultra-fast path: single string comparison, zero allocations ─
            if b1 == b2:
                continue

            # ── Slow path: full parse for cycle-CSR tolerance + reporting ───
            t1 = _parse_rtl_entry(l1)
            t2 = _parse_rtl_entry(l2)
            if t1 is None or t2 is None:
                continue

            pc_match    = t1['pc']    == t2['pc']
            instr_match = t1['instr'] == t2['instr']
            reg_match, _ = _reg_match_result(t1, t2)
            mem_match     = t1['mem_access'] == t2['mem_access']
            csr1, csr2    = t1.get('csr_access'), t2.get('csr_access')
            if csr1 and csr2:
                csr_match = (normalize_csr_name(csr1[0]) == normalize_csr_name(csr2[0])
                             and csr1[1] == csr2[1])
            else:
                csr_match = csr1 == csr2

            if pc_match and instr_match and reg_match and mem_match and csr_match:
                continue  # e.g. cycle-CSR with same written value

            disasm1 = f" ; {t1['disasm']}" if t1.get('disasm') else ""
            disasm2 = f" ; {t2['disasm']}" if t2.get('disasm') else ""
            print(f"\nMismatch at entry {entry_num}:")
            print(f"  REF: PC=0x{t1['pc']:08x} INSTR=0x{t1['instr']:08x}{disasm1}")
            print(f"  TGT: PC=0x{t2['pc']:08x} INSTR=0x{t2['instr']:08x}{disasm2}")
            if not pc_match or not instr_match:
                print("  >>> PC/Instruction mismatch <<<")
            if not reg_match:
                r1, r2 = t1.get('reg_write'), t2.get('reg_write')
                print(f"  REF reg: {r1[0]}=0x{r1[1]:08x}" if r1 else "  REF reg: none")
                print(f"  TGT reg: {r2[0]}=0x{r2[1]:08x}" if r2 else "  TGT reg: none")
            if not mem_match:
                m1, m2 = t1.get('mem_access'), t2.get('mem_access')
                print(f"  REF mem: {m1[2]} addr=0x{m1[0]:08x} data=0x{m1[1]:08x}" if m1 else "  REF mem: none")
                print(f"  TGT mem: {m2[2]} addr=0x{m2[0]:08x} data=0x{m2[1]:08x}" if m2 else "  TGT mem: none")
            if not csr_match:
                print(f"  REF csr: {csr1[0]}=0x{csr1[1]:08x}" if csr1 else "  REF csr: none")
                print(f"  TGT csr: {csr2[0]}=0x{csr2[1]:08x}" if csr2 else "  TGT csr: none")
            mismatches += 1
            if mismatches >= 10:
                print("\n... stopping after 10 mismatches")
                break
    except StopIteration:
        pass

    # Drain the longer stream for accurate length reporting
    for _ in iter1:
        n1 += 1
    for _ in iter2:
        n2 += 1

    print(f"REF (RTL) entries: {n1}")
    print(f"TGT (RTL) entries: {n2}")
    if mismatches == 0:
        if n1 == n2:
            print("\n[PASS] Traces match perfectly!")
            return 0
        elif n1 < n2:
            print(f"\n[PASS] All {n1} REF instructions match TGT")
            print(f"  (TGT continued for {n2 - n1} more instructions)")
            return 0
        else:
            print(f"\n[PASS] All TGT instructions matched, but REF has {n1 - n2} extra entries")
            return 0
    else:
        print(f"\n[FAIL] Found {mismatches} mismatches")
        if n1 != n2:
            print(f"  Length mismatch: REF={n1} TGT={n2}")
        return 1

def _reg_match_result(t1, t2):
    """
    Compare the reg_write fields of two trace entries and return
    (match: bool, skip_reason: str|None).

    Handles two special cases:
      1. Cycle-counter CSRs: compare register name only (values differ by CPI).
      2. CSR RMW cross-format: spike logs the rd write while kv32sim RTL logs
         the CSR write.  When one side has a CSR-name and the other has a
         standard register name for the same csrrw/csrrs/csrrc instruction,
         treat it as a format difference and skip (not a bug).
    """
    r1 = t1.get('reg_write')
    r2 = t2.get('reg_write')

    # ── cycle-counter CSR reads ──────────────────────────────────────────────
    if t1.get('is_cycle_csr') and t2.get('is_cycle_csr'):
        if r1 and r2:
            return r1[0] == r2[0], None   # compare name only
        return r1 == r2, None

    # ── CSR RMW instructions (csrrw / csrrs / csrrc / csrrwi / csrrsi / csrrci)
    if t1.get('is_csr_rw') or t2.get('is_csr_rw'):
        if r1 and r2:
            r1_is_csr = is_csr_name(r1[0])
            r2_is_csr = is_csr_name(r2[0])
            if r1_is_csr != r2_is_csr:
                # Cross-format: one side reports rd write (spike), the other
                # reports the CSR write (kv32sim RTL).  Both are correct — just
                # different aspects of the same instruction.  Skip.
                return True, "csr-format"
            elif r1_is_csr and r2_is_csr:
                # Both report CSR write — compare normalized name + value
                match = (normalize_csr_name(r1[0]) == normalize_csr_name(r2[0])
                         and r1[1] == r2[1])
                return match, None
            else:
                # Both report rd write — compare normally
                return (r1[0] == r2[0]) and (r1[1] == r2[1]), None
        # One side has no write recorded (e.g. rd=zero → no log entry)
        # Be lenient: a missing write on either side is OK for CSR RMW
        return True, "csr-format"

    # ── ordinary instructions ─────────────────────────────────────────────────
    if r1 and r2:
        r1_name = normalize_csr_name(r1[0])
        r2_name = normalize_csr_name(r2[0])
        return (r1_name == r2_name) and (r1[1] == r2[1]), None
    return r1 == r2, None

def compare_traces(traces1, traces2, name1="Trace1", name2="Trace2"):
    """Compare two traces (generic comparison)"""
    print(f"REF ({name1}) entries: {len(traces1)}")
    print(f"TGT ({name2}) entries: {len(traces2)}")

    # Detect spike vs kv32sim-RTL comparison so we can note it up front
    types1 = {e.get('trace_type') for e in traces1}
    types2 = {e.get('trace_type') for e in traces2}
    cross_format = ('spike' in types1 and 'rtl' in types2) or \
                   ('rtl' in types1 and 'spike' in types2)
    if cross_format:
        print("Note: spike vs kv32sim comparison — CSR RMW instructions log"
              " different sides (rd-write vs CSR-write); those are skipped.")

    # Fail if either trace is empty
    if len(traces1) == 0 or len(traces2) == 0:
        print(f"\n[FAIL] One or both traces are empty")
        return 1

    # Find where traces align (skip bootloader if necessary)
    # Try aligning trace2 to trace1 first
    trace1_start_pc = traces1[0]['pc']
    trace2_start_pc = traces2[0]['pc']
    trace1_offset = 0
    trace2_offset = 0

    # First try: find trace1's start PC in trace2 (skip boot ROM in trace2)
    for i, entry in enumerate(traces2):
        if entry['pc'] == trace1_start_pc:
            trace2_offset = i
            if trace2_offset > 0:
                print(f"Aligning traces: TGT offset = {trace2_offset} (skipping bootloader)")
            break

    # Second try: if trace2_offset is still 0 and PCs don't match,
    # find trace2's start PC in trace1 (skip boot ROM in trace1)
    if trace2_offset == 0 and trace1_start_pc != trace2_start_pc:
        for i, entry in enumerate(traces1):
            if entry['pc'] == trace2_start_pc:
                trace1_offset = i
                if trace1_offset > 0:
                    print(f"Aligning traces: REF offset = {trace1_offset} (skipping bootloader)")
                break

    # If still no alignment found, fail
    if trace1_offset == 0 and trace2_offset == 0 and trace1_start_pc != trace2_start_pc:
        print(f"\n[FAIL] Cannot align traces - REF starts at 0x{trace1_start_pc:08x}, TGT starts at 0x{trace2_start_pc:08x}")
        return 1

    mismatches = 0
    deferred_store_skips = 0  # RTL store entries skipped due to deferred fault

    # Use separate pointers so we can skip TGT (RTL) entries that represent
    # deferred-fault stores.  In Spike's immediate-fault model the faulting
    # store is never committed (not logged); in the RTL's deferred model it IS
    # committed before the B-channel SLVERR arrives, so it appears in the RTL
    # trace but not in Spike's.  Lookahead of 2 is enough (store + possible
    # FENCE between commit and SLVERR detection), but use 4 for safety.
    DEFERRED_STORE_LOOKAHEAD = 4
    i1 = trace1_offset   # REF (Spike) pointer
    i2 = trace2_offset   # TGT (RTL) pointer
    entry_num = 0        # logical entry number for mismatch messages

    while i1 < len(traces1) and i2 < len(traces2):
        t1 = traces1[i1]
        t2 = traces2[i2]

        pc_match    = t1['pc']    == t2['pc']
        instr_match = t1['instr'] == t2['instr']

        # ── Fast path: skip all function/branch overhead for the common
        # all-matching case (~99 % of RTL-vs-RTL iterations).
        # Direct equality is correct for RTL-vs-RTL because both sides use the
        # same CSR-name prefixes; the cycle-CSR value difference would make
        # reg_write unequal here, falling through to the slow path correctly.
        if (not cross_format and pc_match and instr_match and
                t1['reg_write']  == t2['reg_write'] and
                t1['mem_access'] == t2['mem_access']):
            i1 += 1
            i2 += 1
            entry_num += 1
            continue
        # ─────────────────────────────────────────────────────

        # Spike vs RTL cross-format: skip RTL store entries for deferred bus
        # faults.  RTL logs the faulting store before B-channel SLVERR arrives;
        # Spike does not (store is never committed).  Detect by: PC mismatch +
        # TGT is a store + looking ahead in TGT finds REF's current PC.
        if not pc_match and cross_format and t2.get('is_store') and t2.get('trace_type') == 'rtl':
            for skip in range(1, DEFERRED_STORE_LOOKAHEAD + 1):
                if (i2 + skip < len(traces2) and
                        traces2[i2 + skip]['pc'] == t1['pc']):
                    deferred_store_skips += skip
                    i2 += skip
                    t2 = traces2[i2]
                    pc_match    = t1['pc']    == t2['pc']
                    instr_match = t1['instr'] == t2['instr']
                    break

        entry_num += 1
        reg_match, reg_skip_reason = _reg_match_result(t1, t2)

        # For AMO/LR/SC instructions (RV32A, opcode 0x2f), kv32sim RTL trace
        # never emits a mem field while the RTL verilator trace emits the
        # memory address (no data).  Skip the mem comparison for any pair that
        # includes an AMO/LR/SC — this applies to both cross-format and same-
        # format (RTL-vs-RTL / kv32sim-vs-RTL) comparisons.
        if t1.get('is_amo') or t2.get('is_amo'):
            mem_match = True
        elif cross_format and (t1.get('is_store') or t2.get('is_store')):
            # sb/sh: spike logs the byte/halfword-masked store data; kv32sim logs
            # the full 32-bit register value.  Apply the store-width mask to both
            # sides before comparing so the difference is not a false mismatch.
            m1 = t1.get('mem_access')
            m2 = t2.get('mem_access')
            if m1 and m2:
                smask = get_store_data_mask(t1['instr'])  # same instr on both sides
                mem_match = (m1[0] == m2[0] and
                             (m1[1] & smask) == (m2[1] & smask) and
                             m1[2] == m2[2])
            else:
                mem_match = m1 == m2
        else:
            mem_match = t1.get('mem_access') == t2.get('mem_access')

        # Compare CSR access with normalized names (RTL uses hex addr prefix,
        # Spike uses decimal addr prefix, e.g. c300_ vs c768_ both = mstatus)
        csr1 = t1.get('csr_access')
        csr2 = t2.get('csr_access')
        if csr1 and csr2:
            csr1_norm = (normalize_csr_name(csr1[0]), csr1[1], csr1[2])
            csr2_norm = (normalize_csr_name(csr2[0]), csr2[1], csr2[2])
            csr_match = csr1_norm == csr2_norm
        else:
            csr_match = csr1 == csr2

        if not (pc_match and instr_match and reg_match and mem_match and csr_match):
            disasm1 = f" ; {t1['disasm']}" if t1.get('disasm') else ""
            disasm2 = f" ; {t2['disasm']}" if t2.get('disasm') else ""
            print(f"\nMismatch at entry {entry_num}:")
            print(f"  REF: PC=0x{t1['pc']:08x} INSTR=0x{t1['instr']:08x}{disasm1}")
            print(f"  TGT: PC=0x{t2['pc']:08x} INSTR=0x{t2['instr']:08x}{disasm2}")

            if not pc_match or not instr_match:
                print(f"  >>> PC/Instruction mismatch <<<")

            if not reg_match:
                r1 = t1.get('reg_write')
                r2 = t2.get('reg_write')
                print(f"  REF reg: {r1[0] if r1 else 'none'}=0x{r1[1]:08x}" if r1 else "  REF reg: none")
                print(f"  TGT reg: {r2[0] if r2 else 'none'}=0x{r2[1]:08x}" if r2 else "  TGT reg: none")

            if not mem_match:
                m1 = t1.get('mem_access')
                m2 = t2.get('mem_access')
                print((f"  REF mem: {m1[2]} addr=0x{m1[0]:08x} data=0x{m1[1]:08x}") if m1 else "  REF mem: none")
                print((f"  TGT mem: {m2[2]} addr=0x{m2[0]:08x} data=0x{m2[1]:08x}") if m2 else "  TGT mem: none")

            if not csr_match:
                c1 = t1.get('csr_access')
                c2 = t2.get('csr_access')
                print((f"  REF csr: {c1[0]}=0x{c1[1]:08x}") if c1 else "  REF csr: none")
                print((f"  TGT csr: {c2[0]}=0x{c2[1]:08x}") if c2 else "  TGT csr: none")

            mismatches += 1
            if mismatches >= 10:
                print("\n... stopping after 10 mismatches")
                break

        i1 += 1
        i2 += 1

    if deferred_store_skips > 0:
        print(f"Note: skipped {deferred_store_skips} RTL deferred-fault store(s) "
              f"not present in Spike trace (RTL deferred B-channel SLVERR model).")

    effective_trace1_len = len(traces1) - trace1_offset
    # Subtract deferred-store skips from TGT length for accurate "extra" reporting
    effective_trace2_len = len(traces2) - trace2_offset - deferred_store_skips
    if mismatches == 0:
        if effective_trace1_len == effective_trace2_len:
            print(f"\n[PASS] Traces match perfectly!")
            return 0
        elif effective_trace1_len < effective_trace2_len:
            print(f"\n[PASS] All {effective_trace1_len} REF instructions match TGT")
            print(f"  (TGT continued for {effective_trace2_len - effective_trace1_len} more instructions)")
            return 0
        else:
            print(f"\n[PASS] All TGT instructions matched, but REF has {effective_trace1_len - effective_trace2_len} extra entries")
            return 0
    else:
        print(f"\n[FAIL] Found {mismatches} mismatches")
        if effective_trace1_len != effective_trace2_len:
            print(f"  Length mismatch: REF={effective_trace1_len} TGT={effective_trace2_len}")
        return 1

def compare_three_way(rtl_traces, spike_traces, kv32sim_traces):
    """Three-way comparison of RTL, Spike, and kv32sim traces"""
    print("=== Three-Way Trace Comparison ===\n")
    print(f"RTL entries:     {len(rtl_traces)}")
    print(f"Spike entries:   {len(spike_traces)}")
    print(f"kv32sim entries: {len(kv32sim_traces)}\n")

    # Align all three traces
    rtl_start = rtl_traces[0]['pc'] if rtl_traces else 0
    spike_offset = 0
    kv32sim_offset = 0

    for i, entry in enumerate(spike_traces):
        if entry['pc'] == rtl_start:
            spike_offset = i
            break

    for i, entry in enumerate(kv32sim_traces):
        if entry['pc'] == rtl_start:
            kv32sim_offset = i
            break

    if spike_offset > 0:
        print(f"Spike alignment offset: {spike_offset}")
    if kv32sim_offset > 0:
        print(f"kv32sim alignment offset: {kv32sim_offset}")

    mismatches = 0
    max_compare = min(
        len(rtl_traces),
        len(spike_traces) - spike_offset,
        len(kv32sim_traces) - kv32sim_offset
    )

    for i in range(max_compare):
        rtl = rtl_traces[i]
        spike = spike_traces[i + spike_offset]
        kv32 = kv32sim_traces[i + kv32sim_offset]

        pc_match = rtl['pc'] == spike['pc'] == kv32['pc']
        instr_match = rtl['instr'] == spike['instr'] == kv32['instr']

        # For cycle counter CSR reads, only check register name matches, not value
        if rtl.get('is_cycle_csr') and spike.get('is_cycle_csr') and kv32.get('is_cycle_csr'):
            r_rtl = rtl.get('reg_write')
            r_spike = spike.get('reg_write')
            r_kv32 = kv32.get('reg_write')
            if r_rtl and r_spike and r_kv32:
                reg_match = r_rtl[0] == r_spike[0] == r_kv32[0]  # Compare only register names
            else:
                reg_match = rtl.get('reg_write') == spike.get('reg_write') == kv32.get('reg_write')
        else:
            reg_match = rtl.get('reg_write') == spike.get('reg_write') == kv32.get('reg_write')

        mem_match = rtl.get('mem_access') == spike.get('mem_access') == kv32.get('mem_access')
        csr_match = rtl.get('csr_access') == spike.get('csr_access') == kv32.get('csr_access')

        if not (pc_match and instr_match and reg_match and mem_match and csr_match):
            print(f"\nMismatch at entry {i+1}:")

            # Always show PC/Instruction/disassembly for context
            disasm_rtl = f" ; {rtl['disasm']}" if rtl.get('disasm') else ""
            disasm_spike = f" ; {spike['disasm']}" if spike.get('disasm') else ""
            disasm_kv32 = f" ; {kv32['disasm']}" if kv32.get('disasm') else ""
            print(f"  RTL:     PC=0x{rtl['pc']:08x} INSTR=0x{rtl['instr']:08x}{disasm_rtl}")
            print(f"  Spike:   PC=0x{spike['pc']:08x} INSTR=0x{spike['instr']:08x}{disasm_spike}")
            print(f"  kv32sim: PC=0x{kv32['pc']:08x} INSTR=0x{kv32['instr']:08x}{disasm_kv32}")

            # Highlight PC/Instruction difference if present
            if not pc_match or not instr_match:
                print(f"  >>> PC/Instruction mismatch <<<")

            # Register write mismatch
            if not reg_match:
                r_rtl = rtl.get('reg_write')
                r_spike = spike.get('reg_write')
                r_kv32 = kv32.get('reg_write')
                print(f"  RTL reg:     {r_rtl[0] if r_rtl else 'none'}={hex(r_rtl[1]) if r_rtl else 'N/A'}")
                print(f"  Spike reg:   {r_spike[0] if r_spike else 'none'}={hex(r_spike[1]) if r_spike else 'N/A'}")
                print(f"  kv32sim reg: {r_kv32[0] if r_kv32 else 'none'}={hex(r_kv32[1]) if r_kv32 else 'N/A'}")

            # Memory access mismatch
            if not mem_match:
                m_rtl = rtl.get('mem_access')
                m_spike = spike.get('mem_access')
                m_kv32 = kv32.get('mem_access')
                if m_rtl:
                    print(f"  RTL mem:     {m_rtl[2]} addr=0x{m_rtl[0]:08x} data=0x{m_rtl[1]:08x}")
                else:
                    print(f"  RTL mem:     none")
                if m_spike:
                    print(f"  Spike mem:   {m_spike[2]} addr=0x{m_spike[0]:08x} data=0x{m_spike[1]:08x}")
                else:
                    print(f"  Spike mem:   none")
                if m_kv32:
                    print(f"  kv32sim mem: {m_kv32[2]} addr=0x{m_kv32[0]:08x} data=0x{m_kv32[1]:08x}")
                else:
                    print(f"  kv32sim mem: none")

            # CSR access mismatch
            if not csr_match:
                c_rtl = rtl.get('csr_access')
                c_spike = spike.get('csr_access')
                c_kv32 = kv32.get('csr_access')
                if c_rtl:
                    print(f"  RTL csr:     {c_rtl[0]}=0x{c_rtl[1]:08x}")
                else:
                    print(f"  RTL csr:     none")
                if c_spike:
                    print(f"  Spike csr:   {c_spike[0]}=0x{c_spike[1]:08x}")
                else:
                    print(f"  Spike csr:   none")
                if c_kv32:
                    print(f"  kv32sim csr: {c_kv32[0]}=0x{c_kv32[1]:08x}")
                else:
                    print(f"  kv32sim csr: none")

            mismatches += 1
            if mismatches >= 10:
                print("\n... stopping after 10 mismatches")
                break

    if mismatches == 0:
        print(f"\n[PASS] All three traces match for {max_compare} instructions!")
        return 0
    else:
        print(f"\n[FAIL] Found {mismatches} mismatches in three-way comparison")
        return 1
def main():
    parser = argparse.ArgumentParser(
        description='Compare execution traces from RTL, Spike, and kv32sim (first file is reference, second is target)',
        epilog='''
Examples:
  # Two-way comparisons (first=REF, second=TGT)
  %(prog)s build/sim_trace.txt build/rtl_trace.txt   # Compare sim (REF) vs RTL (TGT)
  %(prog)s spike_trace.txt build/rtl_trace.txt       # Compare Spike (REF) vs RTL (TGT)
  %(prog)s spike_trace1.txt spike_trace2.txt

  # Three-way comparison
  %(prog)s --rtl build/rtl_trace.txt --spike spike.txt --kv32sim sim.txt
        ''',
        formatter_class=argparse.RawDescriptionHelpFormatter
    )

    # Support both positional and named arguments
    parser.add_argument('trace1', nargs='?', help='Reference trace file (REF)')
    parser.add_argument('trace2', nargs='?', help='Target trace file (TGT)')
    parser.add_argument('--rtl', help='RTL trace file (for three-way comparison)')
    parser.add_argument('--spike', help='Spike trace file (for three-way comparison)')
    parser.add_argument('--kv32sim', help='kv32sim trace file (for three-way comparison)')

    args = parser.parse_args()

    try:
        # Three-way comparison mode
        if args.rtl and args.spike and args.kv32sim:
            print(f"Comparing three traces:")
            print(f"  RTL:     {args.rtl}")
            print(f"  Spike:   {args.spike}")
            print(f"  kv32sim: {args.kv32sim}\n")

            rtl_traces = normalize_rtl_trace(parse_rtl_trace(args.rtl))
            spike_traces = parse_spike_trace(args.spike)
            kv32sim_traces = parse_spike_trace(args.kv32sim)

            result = compare_three_way(rtl_traces, spike_traces, kv32sim_traces)
            sys.exit(result)

        # Two-way comparison mode
        elif args.trace1 and args.trace2:
            print(f"Comparing two traces:")
            print(f"  REF (reference): {args.trace1}")
            print(f"  TGT (target):    {args.trace2}\n")

            # Auto-detect trace formats
            type1 = detect_trace_type(args.trace1)
            type2 = detect_trace_type(args.trace2)

            # RTL-vs-RTL: use the streaming fast path.  This avoids running the
            # full regex + dict allocation for the ~99%+ of lines that match;
            # only mismatching lines are fully parsed.  Also handles in-line
            # dedup of consecutive (PC, INSTR) stall-duplicate entries.
            if type1 == 'rtl' and type2 == 'rtl':
                result = compare_rtl_rtl_streaming(args.trace1, args.trace2)
                sys.exit(result)

            print(f"Detected formats: {type1} (REF) vs {type2} (TGT)\n")

            if type1 == 'rtl':
                traces1 = normalize_rtl_trace(parse_rtl_trace(args.trace1))
                name1 = "RTL"
            elif type1 == 'spike':
                traces1 = parse_spike_trace(args.trace1)
                name1 = "Spike/kv32sim"
            else:
                print(f"Error: Unknown format for {args.trace1}")
                sys.exit(1)

            if type2 == 'rtl':
                traces2 = normalize_rtl_trace(parse_rtl_trace(args.trace2))
                name2 = "RTL"
            elif type2 == 'spike':
                traces2 = parse_spike_trace(args.trace2)
                name2 = "Spike/kv32sim"
            else:
                print(f"Error: Unknown format for {args.trace2}")
                sys.exit(1)

            result = compare_traces(traces1, traces2, name1, name2)
            sys.exit(result)

        else:
            parser.print_help()
            sys.exit(1)

    except FileNotFoundError as e:
        print(f"Error: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == '__main__':
    main()
