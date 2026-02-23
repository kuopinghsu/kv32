### Description

Hello, I think I found a bug of srv32. Specifically, The core fails to trigger an Illegal Instruction exception (0x2) when a write-operation is attempted on the read-only cycle CSR (0xC00).

According to the RISC-V Privileged Architecture Specification:

- The `cycle` register is a read-only shadow of the mcycle `CSR`.
- Attempts to write to a read-only CSR must raise an **illegal instruction exception**.
- For CSRRS/CSRRC (and their immediate forms `csrrsi/csrrci`), if the `rs1` (or `uimm`) field is **non-zero**, it is treated as a write-operation.

In this case, `csrrsi x17, cycle, 13` uses an immediate value of `13`, which should trigger the exception.

**Comparison Table:** 
Implementation | Instruction | x17 Result | Exception (Cause) | Status
-- | -- | -- | -- | --
Spike | csrrsi x17, cycle, 13 | 0xbdb6e240 | 0x2 (Illegal Instruction) | Correct
Srv32 | csrrsi x17, cycle, 13 | 0xbdb6e240 | None | Bug

**Steps to Reproduce:**

1. Load the instruction `0xc006be73` (`csrrsi x17, 0xC00, 13`) into memory.
2. Execute the instruction on Srv32.
3. Observe that Srv32 updates `x17` and continues to the next instruction instead of trapping to the exception handler.

Expected Behavior: The hardware should decode the CSR address 0xC00 and the write-intent (uimm != 0), then immediately raise an illegal instruction exception (Cause 2).

