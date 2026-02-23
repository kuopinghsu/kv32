### Summary

When executing csrrc x18, instret, x19 with x19 != x0, Spike raises an Illegal Instruction exception (mcause=2), while Srv32 executes without any exception. This suggests Srv32 may be missing CSR privilege/RO checks (or mishandling counter CSRs).

### Expected Behavior

According to the RISC-V privileged spec, the cycle/instret CSRs are read-only shadows of machine counters; attempts to write a read-only CSR should raise an Illegal Instruction exception. Also, for CSRRC/CSRRS, only when rs1 == x0 does the instruction avoid writing and thus should not raise an illegal-instruction exception on a read-only CSR. 

Therefore, with rs1 = x19 (non-zero), csrrc should trap with mcause=2.

### Actual Behavior

Srv32 does not raise an exception for the same instruction and register context.

### Reproduction

Impl | Instruction | Register Context | Exception
-- | -- | -- | -- 
Spike | csrrc x18, instret, x19 | x18=0x0, x19=0x1bc141a3 | mcause=0x2
Srv32 | csrrc x18, instret, x19 | x18=0x0, x19=0x1bc141a3 |  none

