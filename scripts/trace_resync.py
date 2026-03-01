#!/usr/bin/env python3
"""
Re-syncing trace comparator: identifies exact extra/missing instructions
between two RISC-V instruction traces.
"""
import re
import sys

def parse_trace(fname):
    entries = []
    with open(fname) as f:
        for line in f:
            m = re.match(r'^\s*(\d+)\s+(0x[0-9a-fA-F]+)', line)
            if m:
                seq = int(m.group(1))
                pc = m.group(2)
                entries.append((seq, pc))
    return entries

def main():
    sim_file = sys.argv[1] if len(sys.argv) > 1 else 'build/sim_trace.txt'
    rtl_file = sys.argv[2] if len(sys.argv) > 2 else 'build/rtl_trace.txt'

    sim = parse_trace(sim_file)
    rtl = parse_trace(rtl_file)

    print(f'SIM: {len(sim)} entries, seq {sim[0][0]}..{sim[-1][0]}')
    print(f'RTL: {len(rtl)} entries, seq {rtl[0][0]}..{rtl[-1][0]}')

    sim_i, rtl_i = 0, 0
    rtl_extra = 0
    sim_extra = 0
    divergences = []

    LOOKAHEAD = 20

    while sim_i < len(sim) and rtl_i < len(rtl):
        if sim[sim_i][1] == rtl[rtl_i][1]:
            sim_i += 1
            rtl_i += 1
        else:
            found = False
            for skip_rtl in range(1, LOOKAHEAD):
                if rtl_i + skip_rtl < len(rtl) and rtl[rtl_i + skip_rtl][1] == sim[sim_i][1]:
                    extra_seqs = [rtl[rtl_i + k][0] for k in range(skip_rtl)]
                    extra_pcs  = [rtl[rtl_i + k][1] for k in range(skip_rtl)]
                    msg = (f'RTL has {skip_rtl} extra before sim[{sim_i}]=seq{sim[sim_i][0]}/PC={sim[sim_i][1]} '
                           f'-> RTL seqs {extra_seqs} PCs {extra_pcs}')
                    divergences.append(msg)
                    rtl_extra += skip_rtl
                    rtl_i += skip_rtl
                    found = True
                    break
            if not found:
                for skip_sim in range(1, LOOKAHEAD):
                    if sim_i + skip_sim < len(sim) and sim[sim_i + skip_sim][1] == rtl[rtl_i][1]:
                        extra_seqs = [sim[sim_i + k][0] for k in range(skip_sim)]
                        extra_pcs  = [sim[sim_i + k][1] for k in range(skip_sim)]
                        msg = (f'SIM has {skip_sim} extra before rtl[{rtl_i}]=seq{rtl[rtl_i][0]}/PC={rtl[rtl_i][1]} '
                               f'-> SIM seqs {extra_seqs} PCs {extra_pcs}')
                        divergences.append(msg)
                        sim_extra += skip_sim
                        sim_i += skip_sim
                        found = True
                        break
            if not found:
                print(f'Cannot resync at sim_i={sim_i}/seq{sim[sim_i][0]}/PC={sim[sim_i][1]} '
                      f'vs rtl_i={rtl_i}/seq{rtl[rtl_i][0]}/PC={rtl[rtl_i][1]}')
                sim_i += 1
                rtl_i += 1

    print(f'\nRTL total extra: {rtl_extra}')
    print(f'SIM total extra: {sim_extra}')
    print(f'Net RTL - SIM:   {rtl_extra - sim_extra}')
    print()
    print('Divergences:')
    for d in divergences:
        print(' ', d)

if __name__ == '__main__':
    main()
