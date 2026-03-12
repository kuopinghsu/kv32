# KV32 TODO

## Pending

### 1. RISC-V Debug Interface
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

### 2. Zephyr RTOS Porting Update
**Priority: MEDIUM** — Keeps RTOS support current.
- [ ] Bring the Zephyr port up to date with the latest kernel version.
- [ ] Resolve any outstanding porting issues.

### 3. GitHub CI Workflow
**Priority: LOW** — Improves project hygiene; no functional dependency.
- [ ] Add a GitHub Actions workflow that builds the simulator, runs lint, and
  executes the regression suite on every push and pull request.

### 4. Google RISCV-DV Integration
**Priority: LOW** — Broad verification; high effort, no prerequisite blockers.
- [ ] Evaluate and run the Google RISC-V DV random instruction test suite against the kv32 RTL.

### 5. FuseSoC Support
**Priority: LOW** — Enables standard IP packaging and integration with third-party EDA flows.
- [ ] Create a top-level `kv32_soc.core` FuseSoC core description file: declare all RTL source files (`rtl/`, `rtl/core/`, `rtl/jtag/`, `rtl/memories/`), testbench files (`testbench/`), and parameters (`CLK_FREQ`, `BAUD_RATE`, `ICACHE_EN`, `ICACHE_SIZE`, etc.).
- [ ] Add a `fusesoc_libraries.conf` (or `fusesoc.conf`) at the repo root pointing to the local core library.
- [ ] Define at least two named targets in the `.core` file: `sim` (Verilator backend, mirrors the existing `Makefile` flow) and `synth` (Yosys or Genus backend for synthesis).
- [ ] Verify `fusesoc run --target sim kv32::kv32_soc` reproduces the existing Verilator simulation results for a representative test (e.g. `hello`).
- [ ] Add a `make fusesoc-sim` convenience target to the top-level `Makefile`.
- [ ] Package peripheral cores (`axi_uart`, `axi_dma`, `axi_spi`, `axi_i2c`, `axi_gpio`, `axi_timer`, `axi_clint`, `axi_plic`) as individual `.core` files so they can be reused independently.
- [ ] Document setup in a new `docs/fusesoc_integration.md`: installation, core file layout, available targets, and how to add a new peripheral core.

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

### ~~C8. Doxygen Documentation~~
- Added `Doxyfile` at repo root: `INPUT=sw/include,sim,rtl`, `RECURSIVE=YES`, `EXTRACT_ALL=YES`, `GENERATE_HTML=YES`, `OUTPUT_DIRECTORY=docs/doxygen`.
- Wrote `scripts/doxygen_sv_filter.py`: custom SV→C++ filter (module/endmodule → class/};, preserves `/** */` comments) since `doxygen-filter-sv` is not on PyPI; configured via `FILTER_PATTERNS` and `EXTENSION_MAPPING=sv=C++`.
- Annotated all `sw/include/*.h` with `@file`/`@brief`/`@defgroup`/`@ingroup` and per-function `/** @brief @param @return */` doc-comments.
- Annotated `sim/kv32sim.h`, `sim/device.h`, and `sim/gdb_stub.h` with full Doxygen class/struct/function documentation.
- Added `/** @brief @ingroup rtl */` above `module` declarations in `kv32_soc.sv`, `kv32_core.sv`, `kv32_icache.sv`, and all `axi_*.sv` peripherals; `@see` cross-links to `docs/kv32_soc_datasheet.adoc`.
- Added `make docs` target to top-level `Makefile`.
- Added `docs/doxygen/` to `.gitignore`.
- `make docs` builds with zero warnings: `docs/doxygen/html/index.html`.

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

### ~~C11. DDR4 Speed-Grade Parameter Support~~
- Extended `MEM_TYPE` Makefile variable to accept DDR4 speed grades:
  `MEM_TYPE=ddr4` (default → DDR4-1600) or `MEM_TYPE=ddr4-<N>` where
  N ∈ {1600, 1866, 2133, 2400, 2666, 2933, 3200}.
- Added `DDR4_1866` and `DDR4_2933` timing entries to `ddr4_axi4_pkg.sv`
  (previously only 1600/2133/2400/2666/3200 were present).
- Replaced 11 individual DDR4 timing parameters (`DDR4_CL`, `DDR4_RCD`,
  `DDR4_RP`, `DDR4_RAS`, `DDR4_RC`, `DDR4_WR`, `DDR4_RTP`, `DDR4_WTR`,
  `DDR4_FAW`, `DDR4_REFI`, `DDR4_RFC`) in `ddr4_axi4_slave.sv` with a
  single `DDR4_SPEED_GRADE` integer; timing is looked up at runtime via
  `ddr4_axi4_pkg::get_ddr4_timing()` in the `initial`/`$display` block.
- Updated `testbench/tb_kv32_soc.sv` to expose a single `DDR4_SPEED_GRADE`
  parameter (default 1600) passed through to `ddr4_axi4_slave`.
- Makefile uses `patsubst` to extract the grade number and passes a single
  `-pvalue+DDR4_SPEED_GRADE=<N>` flag to Verilator; all per-grade `ifeq`
  blocks eliminated. Updated `make help` with DDR4 memory-type examples.
- Regression: all tests PASS for `MEM_TYPE=ddr4` through `MEM_TYPE=ddr4-3200`.

### ~~C12. I2C Clock-Stretching Tests~~
- Extended `testbench/i2c_slave_eeprom.sv` with `STRETCH_CYCLES` parameter and `scl_oe` output;
  slave holds SCL low after each byte ACK for the configured number of clock cycles.
- Wired slave `scl_oe` into the open-drain SCL bus in `testbench/tb_kv32_soc.sv`;
  SCL wire is the wired-AND of master and slave drivers.
- Added `STRETCH=N` Makefile knob (`+define+I2C_STRETCH_CYCLES=N`) so RTL simulations
  rebuild automatically when the stretch value changes.
- Added `test8_scattered_write_read()` (16 individual byte writes/reads to 0x30–0x3F) and
  `test9_block_transfer()` (burst write + sequential read via `kv_i2c_master_write/read`) to
  `sw/i2c/i2c.c`; total test count raised from 7/7 to 9/9.
- Fixed a subtle timing bug: stretch must trigger on `scl_falling` in ACK states (the correct
  I2C protocol hold point), NOT on `scl_rising` in RECV states (which causes a spurious
  `scl_falling` one clock later that misroutes the ACK handler).
- Fixed a pre-existing bug in `sim/device.cpp` `I2CDevice::handle_eeprom_write()`: the old
  value-pattern check `(data & 0xFE) == 0xA0` misidentified data bytes `0xA0/0xA1` (part of the
  default EEPROM fill pattern) as device-address bytes, corrupting test 8's writes. Replaced with
  a proper transaction-state machine (`IDLE → GOT_ADDR → DATA`) mirroring `spike/plugin_i2c.cc`.
- Added `EepromTxState` enum, `eeprom_write_mode`, and `ACK_STRETCH` master state to
  `sim/device.h`; added `stretch_ticks_per_ack` / `stretch_remaining` fields for holding
  `BUSY=1` after each byte ACK (clock-stretch BUSY delay modeling in simulation).
- Added clock-stretch note to `spike/plugin_i2c.cc`: Spike processes all operations
  synchronously so STRETCH has no effect there; the state machine is already functionally correct.
- All tests pass: `make rtl-i2c` 9/9, `make STRETCH=200 rtl-i2c` 9/9,
  `make STRETCH=2000 rtl-i2c` 9/9, `make sim-i2c` 9/9, `make spike-i2c` 9/9. Lint clean.

### ~~C13. I-Cache PMA Bypass + NCM Test Coverage~~
- Implemented PMA-based per-request bypass in `rtl/kv32_icache.sv`: added `pma_cacheable`
  (= `req_addr_r[31]`) and `use_cache` (= `cache_enable & pma_cacheable`) signals. All
  per-request `cache_enable` uses in the state machine, AXI AR channel, fill tracking,
  response mux, and the `p_rlast_on_final_beat` assertion were updated to use `use_cache`.
  The CMO register (`cache_enable`) is unchanged and still controls the global bypass via
  `CMO_DISABLE`/`CMO_ENABLE`.
- Added `DEBUG2` message in `kv32_icache.sv` (`DBG_GRP_ICACHE`) for every PMA-bypass fetch
  (printed when `DEBUG=2 DEBUG_GROUP=0x2000` or `DEBUG_GROUP=0xFFFFFFFF`).
- Added 512B Non-Cacheable Memory (NCM) inside `rtl/axi_magic.sv` (`ifndef SYNTHESIS`):
  128 × 32-bit word array at offset `0x1000` from magic base (`0x4000_1000`).
  Firmware may write machine-code words via MMIO stores and call via function pointer.
  The xbar already routes `0x4000_xxxx` to the magic slave; the magic device now handles
  reads (instruction fetch bypass) and writes (code upload) for the NCM window.
- Added `KV_NCM_BASE` / `KV_NCM_SIZE` / `KV_NCM_OFF` defines to `sw/include/kv_platform.h`.
- Extended `sim/device.h` and `sim/device.cpp` (`MagicDevice`) with 128-word `ncm[]` array;
  `read()` and `write()` now handle the `0x1000–0x11FF` offset range for instruction fetches
  and code uploads.
- Extended `spike/plugin_magic.cc` with the same `ncm[]` array; `load()` serves instruction
  fetches and data reads; `store()` accepts code-upload writes.
- Added Spike ISA flag `_zicbom` to Makefile (`--isa=rv32ima_zicsr_zicntr_zicbom`) so
  `cbo.inval` is recognised as a no-op instead of raising an illegal-instruction trap.
- Removed `icache` from `SPIKE_EXCLUDE`; `spike-icache` (and `spike-all`) now include the
  icache test.
- Added **Test 4** to `sw/icache/icache.c`: copies `hot_loop` to NCM, calls it through a
  function pointer twice, checks result correctness and that call-1 ≈ call-2 cycles (no cache
  warmup). Debug output prints the NCM base address and word-copy progress.
- All tests pass: `make rtl-icache` 4/4 (2 410 PMA bypass fetches visible in stats),
  `make sim-icache` 4/4, `make spike-icache` 4/4. Lint clean.

### ~~C14. DDR4 Simulation Memory Model~~
- Added `testbench/ddr4_axi4_slave.sv` and `testbench/ddr4_axi4_pkg.sv`: a cycle-accurate
  DDR4 slave model with configurable speed grades (1600 / 1866 / 2133 / 2400 / 2666 / 2933 / 3200).
- Added `MEM_TYPE` Makefile variable (`sram` | `ddr4` | `ddr4-<grade>`); selects between
  `testbench/axi_memory.sv` and `ddr4_axi4_slave.sv` at elaboration time.
- ELF loading in `ddr4_axi4_slave.sv` via the same `elfloader` DPI-C interface.
- Regression: all tests pass under both `MEM_TYPE=sram` and `MEM_TYPE=ddr4`.

### ~~C15. I-Cache Benchmark Refresh~~
- Re-ran i-cache configuration sweep (36 configs × 2 benchmarks) with `MEM_TYPE=sram`
  and `MEM_TYPE=ddr4`.
- Added DDR4 analysis sections to `docs/icache_benchmark_report.md`: per-config latency
  impact, hello-world and icache-benchmark comparisons, and full regression status.
- WFI timing test (sub-test 4) margin widened from ±600 to ±1000 cycles to cover DDR4
  cold-cache overhead on the post-wakeup instruction refill path; all 12 WFI sub-tests
  pass under both SRAM and DDR4.

### ~~C16. Synthesis Warning Fixes~~
- Fixed all `CDFG2G-622` (multiple-driver) warnings in Cadence Genus:
  - `rtl/core/kv32_sb.sv`: merged two `always_ff` blocks (alloc/flush and complete/flush)
    driving `buf_valid`, `buf_inflight`, `wr_ptr`, `rd_ptr` into a single block.
  - `rtl/axi_plic.sv`: moved `claimed_r` set-on-claim logic from a separate `always_ff`
    into the existing pending-update block.
  - `rtl/axi_i2c.sv`: consolidated `rxf_push_r` reset and default into the I2C state
    machine `always_ff`; removed duplicate driver in the FIFO block.
  - `rtl/axi_dma.sv`: merged W1C `ch_done`/`ch_err` clearing logic into the engine
    `always_ff`; deleted the standalone W1C block.
- Fixed `CDFG-508` (unused flip-flop) warnings:
  - `rtl/core/kv32_core.sv`: wrapped `csr_wdata_wb`, `csr_zimm_wb`, `csr_addr_wb`
    assignments in `` `ifndef SYNTHESIS `` (DPI-C testbench probes; not needed in gates).
- Fixed `CDFG-472` (unreachable default case) warnings:
  - `rtl/core/kv32_decoder.sv`: removed three `default: illegal = 1'b1` lines inside
    fully-enumerated 3-bit `funct3` case statements.
  - `rtl/kv32_icache.sv`: removed unreachable `default: next_state = S_IDLE`.
  - `rtl/jtag/jtag_tap.sv`: removed unreachable `default: state_next = TEST_LOGIC_RESET`.
- All 25 RTL tests pass; Verilator lint clean.

### ~~C17. RISC-V Architectural Tests (riscv-arch-test)~~
- Integrated the upstream `riscv-arch-test` suite with the kv32 RTL simulation flow via RISCOF.
- Added `verif/riscof_targets/kv32/` plugin (`riscof_kv32.py`): invokes Verilator simulation, captures the signature region, and compares against the Spike reference model.
- Added `make arch-test-rv32i`, `arch-test-rv32m`, `arch-test-rv32a`, `arch-test-rv32zicsr`, `arch-test-rv32c`, and `arch-test-all` (`rv32imac`) targets; each reports pass/fail count.
- Extended `kv32_isa.yaml` to declare `RV32IMACZicsr_Zifencei` so the C-extension suite is selected by RISCOF.
- All tests pass: RV32I, RV32M, RV32A, Zicsr, and RV32C (compressed) suites against Spike reference.
- Documented setup in `verif/riscof_targets/README.md`: Python virtual-environment setup, `riscof` version, reference model (Spike), and expected runtime.

### ~~C18. Compressed Instruction Support (RVC / Zca)~~
- Added `rtl/core/kv32_rvc.sv`: pre-decode expander that detects `inst[1:0] != 2'b11`, expands all RVC (Quadrant 0/1/2) instructions to 32-bit equivalents before the decode stage.
- Updated `rtl/core/kv32_ib.sv`: instruction buffer handles 16-bit-aligned fetch boundaries; packs/unpacks 16-bit and 32-bit instructions correctly across cache-line edges.
- Updated `rtl/core/kv32_core.sv`: PC advances by 2 for compressed instructions (`is_compressed_id/ex` flags); `rvc_instr_pc` carries halfword-aligned PC through the pipeline.
- Updated `rtl/kv32_icache.sv` and fetch path to handle 16-bit-aligned accesses at cache-line boundaries.
- Extended `sim/kv32sim.cpp` and `sim/riscv-dis.cpp` with full RVC decode and execution.
- Updated `-march=rv32imac_zicsr` / `-mabi=ilp32` in `sw/common/Makefile` and Spike `--isa=rv32imac_zicsr_...` flags.
- Added `sw/rvc/rvc.c` test: exercises all major RVC instruction groups (CI, CR, CL, CS, CB, CJ).
- Updated `docs/pipeline_architecture.md` and `docs/kv32_soc_datasheet.adoc` with RVC/`kv32_rvc` expander description and C-extension ISA table entry.
- Updated `misa = 32'h4014_1105` (C bit set) in `rtl/core/kv32_csr.sv` and IDCODE in `rtl/kv32_dtm.sv`.
- All tests pass: `make test-all` 18/18, `make TRACE=1 arch-test-rv32c` 29/29.

### ~~C19. Physical Memory Attributes (PMA) — D-Cache Extension~~
- Extended the PMA cacheability check to the data path in `rtl/kv32_dcache.sv`: `pma_cacheable = req_addr[31]`; addresses with bit[31]=0 (I/O, NCM) bypass the cache and are forwarded as single-beat INCR transactions directly to AXI.
- PMA bypass is applied unconditionally per-request, independent of the global `dcache_enable` CMO register.
- (I-cache PMA bypass, NCM region, and related testbench/simulator changes were completed under C13.)

### ~~C20. D-Cache Implementation~~
- Implemented `rtl/kv32_dcache.sv`: configurable write-back/write-through (`DCACHE_WRITE_BACK`), write-allocate/no-alloc (`DCACHE_WRITE_ALLOC`), N-way set-associative (`DCACHE_WAYS`); SRAM macro wrappers (`sram_1rw`) for tag and data arrays; pseudo-LRU replacement (1 bit per set for 2-way, round-robin pointer for N-way).
- AXI4 interface: critical-word-first WRAP burst fills (AR+R channels), INCR burst dirty-line evictions (AW+W+B channels), single-beat INCR bypasses for non-cacheable (PMA) addresses.
- CMO support: `CBO.INVAL` (invalidate matching line), `CBO.CLEAN` (write-back dirty lines only), `CBO.FLUSH` (write-back + invalidate); `FENCE.I` triggers `CMO_FLUSH_ALL` (write-back all dirty lines + invalidate all).
- Integrated into `kv32_soc.sv` with `DCACHE_EN` parameter (default 1); `DCACHE_EN=0` falls back to `mem_axi` bridge so all data accesses go directly to AXI.
- D-cache performance counters exported from `kv32_soc`: `dcache_perf_req_cnt`, `dcache_perf_hit_cnt`, `dcache_perf_miss_cnt`.
- Store-buffer interaction: D-cache checks the store buffer for forwarding on load hits; cache-miss path drains the store buffer before issuing a fill.
- Added `sw/dcache` test suite: hit/miss, write-back eviction, CMO flush, store-buffer coherency, PMA bypass.
- Updated `sw/dma` to issue `CBO.FLUSH` after DMA transfers to maintain coherency.
- Updated `docs/cache_architecture.md`, `docs/kv32_soc_datasheet.adoc`, and `docs/pipeline_architecture.md` with D-cache architecture, register map, and parameter descriptions.
- Updated synthesis (`syn/`) and FPGA (`fpga/`) compile lists to include `kv32_dcache.sv`.

### ~~C21. DDR4 Delay Model Audit~~
- Checked actual latency model in `testbench/ddr4_axi4_slave.sv` (read/write state machine cycles, burst timing).
- Determined minimum timer period for `MEM_TYPE=ddr4-1866 ICACHE_EN=0` so the WFI stall window is long enough.
- Fixed `sw/wfi/wfi.c` TEST 2 (and timing-sensitive tests) to use DDR4-adjusted periods when I-cache is disabled.