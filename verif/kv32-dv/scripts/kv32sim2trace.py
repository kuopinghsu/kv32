#!/usr/bin/env python3
# ============================================================================
# File: kv32sim2trace.py
# Project: KV32 RISC-V Processor — riscv-dv
# Description: Convert kv32sim instruction trace to riscv-dv CSV trace format.
#
# kv32sim trace format (with --trace):
#   <instr_num>: PC=0x80000000 INSTR=0x00000297 x5=0x80000000  # auipc x5, 0x0
#
# Output CSV columns:
#   pc, instr, gpr, csr, binary, mode, instr_str, operand, pad
#
# Usage:
#   python3 kv32sim2trace.py --log kv32sim.trace --csv kv32sim_trace.csv
# ============================================================================

import argparse
import re
import csv
import sys

def parse_kv32sim_trace(log_path):
    """Parse kv32sim instruction trace into trace entries."""
    entries = []
    # Match kv32sim trace lines:
    # <num>: PC=0x<hex> INSTR=0x<hex> [reg=val ...] # disasm
    pattern = re.compile(
        r'\d+:\s+'
        r'PC=0x([0-9a-fA-F]+)\s+'
        r'INSTR=0x([0-9a-fA-F]+)\s*'
        r'(.*?)(?:\s*#\s*(.*))?$'
    )
    reg_pattern = re.compile(r'(x\d+)=0x([0-9a-fA-F]+)')

    with open(log_path, 'r') as f:
        for line in f:
            line = line.strip()
            m = pattern.match(line)
            if not m:
                continue

            pc = m.group(1).lower()
            binary = m.group(2).lower()
            reg_str = m.group(3).strip()
            disasm = m.group(4) or ''

            gpr = ""
            for rm in reg_pattern.finditer(reg_str):
                reg_name = rm.group(1)
                reg_val = rm.group(2)
                if gpr:
                    gpr += "; "
                gpr += f"{reg_name}:0x{reg_val}"

            entries.append({
                'pc': f"0x{pc}",
                'instr': disasm.strip(),
                'gpr': gpr,
                'csr': '',
                'binary': f"0x{binary}",
                'mode': 'M',
                'instr_str': disasm.strip(),
                'operand': '',
                'pad': '',
            })

    return entries

def write_csv(entries, csv_path):
    """Write trace entries to CSV."""
    fieldnames = ['pc', 'instr', 'gpr', 'csr', 'binary',
                  'mode', 'instr_str', 'operand', 'pad']
    with open(csv_path, 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for entry in entries:
            writer.writerow(entry)

def main():
    parser = argparse.ArgumentParser(
        description='Convert kv32sim trace to riscv-dv CSV trace')
    parser.add_argument('--log', required=True, help='kv32sim trace file')
    parser.add_argument('--csv', required=True, help='Output CSV file')
    args = parser.parse_args()

    entries = parse_kv32sim_trace(args.log)
    if not entries:
        print(f"WARNING: No trace entries parsed from {args.log}",
              file=sys.stderr)
    write_csv(entries, args.csv)
    print(f"Wrote {len(entries)} trace entries to {args.csv}")

if __name__ == '__main__':
    main()
