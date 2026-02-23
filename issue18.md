### Description

Hello, I found, in Srv32, attempts to perform a write operation (where $rs1 \neq x0$) on Machine-mode CSRs (such as `mvendorid`, `marchid`, `mimpid`, and `mhartid`) do not trigger the expected Illegal Instruction exception (0x2).

According to the RISC-V Privileged Architecture Specification, these Machine-mode CSRs are not only restricted by privilege level but are also defined as read-only registers within the Machine-mode address space. The Zicsr extension specifies that for CSRRS instructions, if the source register $rs1$ is not $x0$, it constitutes a write attempt.

### Reproduction Data

Test Case: `csrrs x20, mvendorid, x15` (where `x15 = 0`)

implementation | Instruction | CSR | Resulting x20 | Exception | Status
-- | -- | -- | -- | -- | --
Spike | csrrs x20, 0xf11, x15 | mvendorid | 0x0 | 0x2 | Correct
Srv32 | csrrs x20, 0xf11, x15 | mvendorid | 0x268 | None | Bug

Note: The same behavior is observed for marchid (0xf12), mimpid (0xf13), and mhartid (0xf14). By the way, I found that Srv32 correctly handled `mconfigptr`.


