#!/usr/bin/env python3
# ============================================================================
# File: spike2trace.py
# Project: KV32 RISC-V Processor — riscv-dv
# Description: Convert Spike commit log to riscv-dv CSV trace format.
#
# riscv-dv expects a CSV trace with columns:
#   pc, instr, gpr, csr, binary, mode, instr_str, operand, pad
#
# Spike's --log-commits output format (with -l):
#   core   0: 0x80000000 (0x00000297) x5  0x80000000
#   core   0: 0x80000004 (0x02028293) x5  0x80000048
#   ...
#
# Usage:
#   python3 spike2trace.py --log spike.log --csv spike_trace.csv
# ============================================================================

import argparse
import re
import csv
import sys

def parse_spike_log(log_path):
    """Parse Spike commit log into trace entries."""
    entries = []
    # Match Spike log lines:
    # core   0: 0xPC (0xINSTR) [optional reg writes]
    pattern = re.compile(
        r'core\s+\d+:\s+'
        r'0x([0-9a-fA-F]+)\s+'
        r'\(0x([0-9a-fA-F]+)\)\s*'
        r'(.*)'
    )
    # Match register write: x5  0x80000000 or f5  0x... or ...
    reg_pattern = re.compile(
        r'(x\d+|f\d+|[a-z]+)\s+0x([0-9a-fA-F]+)'
    )
    # Match CSR write (from Spike verbose mode)
    csr_pattern = re.compile(
        r'c(\d+)_([a-z_]+)\s+0x([0-9a-fA-F]+)'
    )

    with open(log_path, 'r') as f:
        for line in f:
            line = line.strip()
            m = pattern.match(line)
            if not m:
                continue

            pc = m.group(1).lower()
            binary = m.group(2).lower()
            rest = m.group(3).strip()

            gpr = ""
            csr = ""

            # Parse register writes
            for rm in reg_pattern.finditer(rest):
                reg_name = rm.group(1)
                reg_val = rm.group(2)
                if reg_name.startswith('x') or reg_name.startswith('f'):
                    if gpr:
                        gpr += "; "
                    gpr += f"{reg_name}:0x{reg_val}"

            # Parse CSR writes
            for cm in csr_pattern.finditer(rest):
                csr_name = cm.group(2)
                csr_val = cm.group(3)
                if csr:
                    csr += "; "
                csr += f"{csr_name}:0x{csr_val}"

            entries.append({
                'pc': f"0x{pc}",
                'instr': '',        # disassembly (not in commit log)
                'gpr': gpr,
                'csr': csr,
                'binary': f"0x{binary}",
                'mode': 'M',        # KV32 is M-mode only
                'instr_str': '',
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
        description='Convert Spike commit log to riscv-dv CSV trace')
    parser.add_argument('--log', required=True, help='Spike log file')
    parser.add_argument('--csv', required=True, help='Output CSV file')
    args = parser.parse_args()

    entries = parse_spike_log(args.log)
    if not entries:
        print(f"WARNING: No trace entries parsed from {args.log}",
              file=sys.stderr)
    write_csv(entries, args.csv)
    print(f"Wrote {len(entries)} trace entries to {args.csv}")

if __name__ == '__main__':
    main()
