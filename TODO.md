# KV32 TODO

## Pending

### 1. Physical Memory Attributes (PMA)
**Priority: HIGH** — Architectural prerequisite for correct cache behavior.
- [ ] Implement PMA check on bit[31] of the physical address:
  - `0` → non-cacheable
  - `1` → cacheable

### 2. D-Cache Implementation
**Priority: HIGH** — Major microarchitecture feature; depends on #1 (PMA) for cacheability policy.
- [ ] Design and implement `kv32_dcache.sv`: write-back, write-allocate, direct-mapped or set-associative.
- [ ] Integrate with the AXI data bus; handle store-buffer interaction (flush / drain on cache miss).
- [ ] Add CMO (Cache Management Operation) support to match the existing I-cache interface.
- [ ] Update `kv32_core.sv` to instantiate D-cache and wire the data-memory interface.
- [ ] Update `kv32_soc.sv` and synthesis / FPGA compile lists.
- [ ] Update the software simulator (`kv32sim`) to model D-cache behavior.
- [ ] Add `sw/dcache` test suite: basic hit/miss, eviction, coherency with store buffer, CMO flush.
- [ ] Update `docs/kv32_soc_datasheet.adoc` and `docs/pipeline_architecture.md`.

### 3. Peripheral WFI Integration
**Priority: HIGH** — Direct follow-up to the completed WFI / clock-gating work.
- [ ] Update `uart.c`: use WFI between transfers to exercise clock gating multiple times.
- [ ] Update `idma.c`, `spi.c`, `i2c.c`: insert WFI where applicable.

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




