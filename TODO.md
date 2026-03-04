# KV32 TODO

## Pending

### 1. Physical Memory Attributes (PMA)
**Priority: HIGH** — Architectural prerequisite for correct cache behavior.
- [ ] Implement PMA check on bit[31] of the physical address:
  - `0` → non-cacheable
  - `1` → cacheable

### 2. D-Cache Implementation
**Priority: HIGH** — Major microarchitecture feature; depends on #1 (PMA) for cacheability policy.
- [ ] Design and implement `kv32_dcache.sv`: write-back, write-allocate, direct-mapped or set-associative. Refer to `kv32_icache.sv` to provide configurable options.
- [ ] Integrate with the AXI data bus; handle store-buffer interaction (flush / drain on cache miss).
- [ ] Add CMO (Cache Management Operation) support to match the existing I-cache interface.
- [ ] Update `kv32_core.sv` to instantiate D-cache and wire the data-memory interface.
- [ ] Update `kv32_soc.sv` and synthesis / FPGA compile lists.
- [ ] Add `sw/dcache` test suite: basic hit/miss, eviction, coherency with store buffer, CMO flush.
- [ ] Update `docs/kv32_soc_datasheet.adoc`, `docs/kv32_soc_block_diagram.svg` and `docs/pipeline_architecture.md`.

### 3. RISC-V Debug Interface
**Priority: HIGH** — First-class debug capability; enables GDB-based bringup and post-silicon-style validation.

#### Phase 1 — Core debug port wiring
- [ ] Add debug ports to `kv32_core.sv`: accept `dbg_halt_req`, drive `dbg_halted` / `dbg_resumeack`, expose GPR read/write and PC read/write buses for the DM.
- [ ] Implement `dcsr` and `dpc` CSRs in `kv32_csr.sv` per RISC-V Debug Spec §4.8.
- [ ] Implement single-step (`dcsr.step`): re-enter debug mode after executing exactly one instruction.
- [ ] Connect `dbg_ndmreset` / `dbg_hartreset` from `kv32_dtm` through `kv32_soc.sv` to the reset network.

#### Phase 2 — Trigger module (hardware breakpoints / watchpoints)
- [ ] Add trigger CSRs to `kv32_csr.sv`: `tselect`, `tdata1`, `tdata2`, `tinfo` (Debug Spec Ch. 5, at least 2 trigger slots).
- [ ] Implement `mcontrol` (type=2) in the EX/MEM stage: PC-match (execute breakpoint) and address-match (load/store watchpoint).
- [ ] Wire trigger-hit to the halt mechanism; report via `dcsr.cause`.

#### Phase 3 — Complete the Debug Module (`kv32_dtm.sv`)
- [ ] Implement abstract command execution (`cmdtype=0` register access; `cmdtype=2` memory access) with correct `abstractcs.busy` / `abstractcs.cmderr` handshake.
- [ ] Implement Program Buffer (`progbuf0`–`progbuf1`) write and `command.postexec` execution path via the CPU fetch mechanism.
- [ ] Implement System Bus Access registers (`sbcs`, `sbaddress0`, `sbdata0`) for direct AXI memory reads and writes without halting the hart.
- [ ] Ensure `abstractauto` re-trigger works for burst memory access from OpenOCD.

#### Phase 4 — VPI remote_bitbang bridge (RTL simulation)
- [ ] Write `testbench/remote_bitbang_vpi.c`: a VPI module that listens on a TCP port (default `9999`) and translates OpenOCD remote_bitbang protocol characters (`B`/`b`/`R`/`Q`/`0`/`1`) into JTAG `TCK`/`TMS`/`TDI`/`TDO`/`TRST` signal toggles.
- [ ] Write `testbench/remote_bitbang.sv`: a SystemVerilog wrapper that calls the VPI tasks and drives/samples the JTAG pins.
- [ ] Integrate into Verilator: add a `JTAG=1` Makefile flag that builds and links the VPI `.so` and wires `jtag_top` to the remote_bitbang module in `tb_kv32_soc.sv`.

#### Phase 5 — OpenOCD configuration
- [ ] Write `openocd/kv32.cfg`: TAP declaration (`-irlen 5 -expected-id 0x1DEAD3FF`), `riscv` target, `riscv set_prefer_sba`, adapter speed.
- [ ] Write `openocd/kv32_cjtag.cfg`: variant selecting `transport select cjtag`.
- [ ] Verify the basic IDE-style flow: `init` → `halt` → `reg` → `resume` → `shutdown` with no errors.

#### Phase 6 — TCL automation test suite
- [ ] `openocd/test_halt_resume.tcl`: halt hart, read and verify PC against reset vector, resume, assert clean exit.
- [ ] `openocd/test_registers.tcl`: write/read all 32 GPRs and key CSRs (`mstatus`, `mepc`, `mcause`) via abstract commands; verify data roundtrip.
- [ ] `openocd/test_memory.tcl`: word/halfword/byte read-write via SBA and abstract-command memory access; verify data integrity.
- [ ] `openocd/test_breakpoint.tcl`: set hardware execute breakpoint; run to breakpoint; verify halted PC; single-step 5 instructions; verify PC sequence.
- [ ] `openocd/test_watchpoint.tcl`: set load/store watchpoint on a test buffer; trigger on data access; verify `dcsr.cause`.
- [ ] `openocd/test_reset.tcl`: `ndmreset` and `hartreset` sequences; verify hart restarts at reset vector.
- [ ] `openocd/test_cjtag.tcl`: repeat halt/resume, register, and memory subtests over cJTAG transport.
- [ ] Add `make jtag-test` Makefile target: launch RTL simulation in background, wait for remote_bitbang socket, run TCL scripts via `openocd -f ... --batch`, report pass/fail.

#### Phase 7 — GDB integration
- [ ] Write `openocd/kv32_gdb.cfg` with `gdb_port 3333`.
- [ ] Add `sw/debug_target/`: a minimal program with known entry, loop, and data buffer addresses for scripted testing.
- [ ] Test: `riscv32-unknown-elf-gdb` attach, `load`, `break`, `continue`, `step`, `info reg`, `x/` memory examine.

#### Phase 8 — Documentation
- [ ] Update `docs/jtag_cjtag_integration.md`: complete DM register map, abstract command protocol, SBA operation, trigger module usage, and OpenOCD/GDB setup instructions.

### 4. I2C Clock-Stretching Tests
**Priority: MEDIUM** — Targeted test coverage gap.
- [ ] Add test cases to `sw/i2c` that exercise the clock-stretching protocol and verify correct RTL behavior.

### 5. DDR4 Simulation Memory Model
**Priority: MEDIUM** — Needed for realistic latency benchmarks (see #6).
- [ ] Add `ddr4_axi4_slave.sv` mapped at `0x8000_0000`.
- [ ] Add `MEM_TYPE` Makefile variable (default: `sram`):
  - `MEM_TYPE=sram` → connect `testbench/axi_memory.sv`
  - `MEM_TYPE=ddr4` → connect `testbench/ddr4_axi4_slave.sv`
- [ ] Support ELF loading in `ddr4_axi4_slave.sv`.

### 6. I-Cache Benchmark Refresh
**Priority: MEDIUM** — Depends on #5 (DDR4 model).
- [ ] Re-run i-cache benchmarks with SRAM latency=1 and the DDR4 model.
- [ ] Update `docs/icache_benchmark_report.md` with new results.

### 7. Zephyr RTOS Porting Update
**Priority: MEDIUM** — Keeps RTOS support current.
- [ ] Bring the Zephyr port up to date with the latest kernel version.
- [ ] Resolve any outstanding porting issues.

### 8. GitHub CI Workflow
**Priority: LOW** — Improves project hygiene; no functional dependency.
- [ ] Add a GitHub Actions workflow that builds the simulator, runs lint, and
  executes the regression suite on every push and pull request.

### 9. Google RISCV-DV Integration
**Priority: LOW** — Broad verification; high effort, no prerequisite blockers.
- [ ] Evaluate and run the Google RISC-V DV random instruction test suite against the kv32 RTL.

---

## Completed

### ~~C1. Null Address Bus-Error Test~~
- Added null pointer load/store and function-call cases to `sw/bus_err`.
- Verified that address-0 accesses on both instruction and data paths raise a bus-error exception.

### ~~C2. Compiler Warnings as Errors~~
- Updated Makefile so that C, C++, and Verilator builds treat all warnings as errors (`-Werror` / `-Wall -Werror`).

### ~~C3. WFI Instruction and Power Management~~
- Implemented WFI: pipeline stalls until an interrupt is pending; an output signal
  indicates "no outstanding requests and store buffer empty" as the condition for clock gating.
- Added `kv32_pm.sv` to gate the clock to `kv32_core`; uses a Xilinx clock-latch primitive for FPGA.
- Added `kv32_pm.sv` to the FPGA and synthesis compile lists.
- Updated the software simulator for WFI support.
- Added `sw/wfi` test.

### ~~C4. Power-Manager Documentation~~
- Updated `README.md`, `docs/kv32_soc_block_diagram.svg`, and `docs/kv32_soc_datasheet.adoc`
  to describe clock-gating behavior.

### ~~C5. RTOS SDK Magic-Address Migration~~
- Updated `rtos/freertos/sys/freertos_syscall.c` to use SDK includes instead of hard-coded magic addresses.
- Updated `rtos/zephyr/drivers/console/` similarly.

### ~~C6. Memory-Map Reorganization~~
Final AXI slave assignment:

| Slave | Peripheral | Base Address       |
|-------|------------|--------------------|
| 0     | ROM/SRAM   | (instruction+data) |
| 1     | Magic      | `0x4000_0000`      |
| 2     | CLINT      | (unchanged)        |
| 3     | PLIC       | (unchanged)        |
| 4     | DMA        | `0x2000_0000`      |
| 5     | UART       | `0x2001_0000`      |
| 6     | I2C        | `0x2002_0000`      |
| 7     | SPI        | `0x2003_0000`      |
| 8     | Timer      | `0x2004_0000`      |
| 9     | GPIO       | `0x2005_0000`      |

- Updated `sw/common/start.S`, `sw/include`, Spike plug-ins and Makefile,
  `README.md`, `docs/kv32_soc_block_diagram.svg`, `docs/kv32_soc_datasheet.adoc`,
  `docs/sdk_api_reference.adoc`.

### ~~C7. Zephyr / FreeRTOS SDK API Migration~~
- Updated `rtos/zephyr/samples`, `rtos/zephyr/soc/riscv/kv32/soc.h`, and `rtos/freertos`
  to use the SDK API.
- Added early-exit guard to `sw/icache`: if `ICACHE_EN=0`, the test exits gracefully
  (verify with `make ICACHE_EN=0 rtl-icache`).

### ~~C8. Dead-Signal (`_unused_ok`) Audit and Cleanup~~
- Audited all `_unused_ok` sinks across the RTL.
- Removed dead signals: `sb_mem_inflight`, `system`/`system_id`/`system_ex` pipeline chain,
  `last_wb_valid`, `amo_op_wb`, `csr_illegal` output port, and `mpie`/`mtie`/`msie`/`meie` CSR aliases.

### ~~C9. `lint_off` Suppression Audit and Cleanup~~
- Audited all `verilator lint_off` pragmas across the RTL; resolved each with a proper code fix:
  - Removed `resp_ready` output port from `kv32_sb` (always-1, no backpressure needed);
    removed the open connection from `kv32_core`.
  - Replaced `WIDTHEXPAND` guard in `mem_axi_ro.sv` with explicit `($bits())'` casts on both operands.
  - Removed dead `axi_arcache` / `axi_arprot` ports from `kv32_icache` (the arbiter has no such
    inputs) and the corresponding open connections from `kv32_soc`.

### ~~C10. Peripheral WFI Integration~~
- Replaced ISR-flag busy-wait spin loops with `kv_wfi()` in `uart.c` (test8), `dma.c` (test3/test7),
  `spi.c` (test8), and `i2c.c` (test7 — two waits: STOP_DONE and RX completion).
- Hardware-register polling loops (e.g. `while (kv_i2c_busy())`) intentionally left as-is;
  `timeout` variable retained in `i2c.c` for those remaining polls.
- All simulator tests pass: uart 8/8, dma 9/9, spi 8/8, i2c 7/7.

