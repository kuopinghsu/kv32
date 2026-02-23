### Description

Hello, I found that an Illegal Instruction exception (`0x2`) is incorrectly raised by Srv32 when executing a csrrci instruction with the uimm field set to 0 targeting a read-only CSR (specifically time, address 0xC01).

In this case, `csrrci x20, time, 0` should be treated as a pure read operation, which is legal for the time CSR.

### Differential Testing Results:
The following trace comparison shows the divergence between the Spike reference model and Srv32:

Implementation | Instruction | Register State (Post) | Exception | Status
-- | -- | -- | -- | --
Spike | csrrci x20, time, 0 | x20 = 0x793 | None | Correct
Srv32 | csrrci x20, time, 0 | - | 0x2 (Illegal Instr) | Bug

### Steps to Reproduce:
1. Load the instruction 0xc0107a73 (csrrci x20, 3073, 0).
2. Execute the instruction on Srv32.
3. Observe that the processor enters the trap handler with mcause = 0x2.

### Expected Behavior:
The processor should:
1. Read the current value of the time CSR into x20.
2. Not attempt a write operation to the CSR.
3. Not raise an exception, as uimm is 0.
