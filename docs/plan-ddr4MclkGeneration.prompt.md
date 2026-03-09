# Plan: DDR4 mclk Generation + Testbench Update

## Overview
`ddr4_axi4_slave.sv` now has separate `aclk`/`aresetn` (AXI, 100 MHz = core clock) and `mclk`/`mresetn`
(DDR4 half-rate, DDR4_SPEED_GRADE/2 MHz). Both clocks must be fully independent and asynchronous.
Generate `mclk` internally inside `tb_kv32_soc.sv` using SV `always #delay` (Verilator `--timing`
already enabled). Update C++ driver to use `contextp->timeInc()` for correct `$time` required by DDR4
timing model. Set `SIM_MEM_DEPTH=524288` (2 MB / 4 bytes = 524 288 32-bit entries).

---

## Clock Relationship (CONFIRMED INDEPENDENT)

| Clock | Domain | Source | Frequency |
|---|---|---|---|
| `clk` | CPU core + AXI | C++ manually toggles | 100 MHz (10 ns / 5000 ps half-period) |
| `mclk` | DDR4 memory | SV `always #delay` | DDR4_SPEED_GRADE÷2 MHz |

Examples of mclk half-period by speed grade (at 1ns/1ps timescale = 1ps resolution):
- DDR4-1600 → 800 MHz → half-period = **625 ps** (exact)
- DDR4-2400 → 1200 MHz → half-period ≈ 417 ps
- DDR4-3200 → 1600 MHz → half-period = 312.5 ps → **313 ps** (rounds at 1ps)

Formula: `MCLK_HALF_PERIOD_NS = 1000.0 / real'(DDR4_SPEED_GRADE)`

The two clocks are **fully asynchronous** — no phase alignment, no integer ratio required. Between every
C++ `clk` half-cycle (5000 ps), Verilator's `--timing` scheduler fires multiple `mclk` edges autonomously.
The DDR4 slave handles the domain crossing via its built-in 4-phase req/ack CDC handshake.

---

## Steps

### Phase 1 — `testbench/tb_kv32_soc.sv`
1. Add `` `timescale 1ns/1ps `` before the module (before the existing lint_off pragma).
2. Inside the `` `ifdef MEM_TYPE_DDR4 `` block, before the instantiation:
   - Add `localparam real MCLK_HALF_PERIOD_NS = 1000.0 / real'(DDR4_SPEED_GRADE);`
     - DDR4-1600 → 0.625 ns; DDR4-3200 → 0.3125 ns
   - Declare `logic mclk = 1'b0;` and the clock generator:
     `/* verilator lint_off COMBDLY */ always #(MCLK_HALF_PERIOD_NS) mclk = ~mclk; /* verilator lint_on COMBDLY */`
   - Declare `logic mresetn, mresetn_meta;` with a 2-FF reset synchroniser on `mclk`:
     `always_ff @(posedge mclk or negedge rst_n) if (!rst_n) {mresetn, mresetn_meta} <= 2'b00; else {mresetn, mresetn_meta} <= {mresetn_meta, 1'b1};`
3. Update DDR4 instantiation — add/change these params/ports:
   - `.mclk(mclk)` and `.mresetn(mresetn)` — new required ports
   - `.SIM_MEM_DEPTH(524288)` — 2 MB at 4 B/entry (was absent → used default 0 = full 1 GB)
   - `.AXI_CLK_PERIOD_NS(10)` — 100 MHz, for informational display
   - `.ENABLE_TIMING_MODEL(1)` — enable real DDR4 tRCD/CL/CWL delays (was absent, default=1)
   - Keep `.ENABLE_TIMING_CHECK(0)` and `.VERBOSE_MODE(0)` as-is.

### Phase 2 — `testbench/tb_kv32_soc.cpp`
4. Replace `main_time` global + `sc_time_stamp()` with Verilator context API:
   - Remove `vluint64_t main_time = 0;`
   - Change `sc_time_stamp()` to: `return Verilated::defaultContextp()->time();`
5. Near the start of `main()`, obtain the context:
   `auto* contextp = Verilated::defaultContextp();`
6. Change **every** half-cycle step in the reset loop and main sim loop from:
   `time_counter++; main_time++;` → `contextp->timeInc(5000);` (5000 ps = 5 ns = one half-period of 100 MHz)
7. Change all waveform dumps from `tfp->dump(time_counter)` → `tfp->dump(contextp->time())`
8. Remove the `time_counter` local variable (replaced by `contextp->time()`).

### Phase 3 — `Makefile`
9. Add `--timescale 1ns/1ps` to both `VERILATOR_FLAGS` and `VERILATOR_LINT_FLAGS`.
10. Update `RTL_BUILD_PARAMS` stamp to include `MEM_TYPE` (already present) — no new stamp entries needed
    as `SIM_MEM_DEPTH` is hardcoded in SV.

---

## Risks / Notes
- Verilator may warn `STMTDLY` (not `COMBDLY`) on the `always #delay` block — if so, replace the
  `lint_off COMBDLY` guard with `lint_off STMTDLY`.
- `--timescale 1ns/1ps` is mandatory — without it Verilator defaults to `1ns/1ns` (1 ns resolution),
  which rounds 625 ps to 1 ns and breaks DDR4-3200 entirely.
- `$time` in the DDR4 timing model (used by `tREFI`, `tWTR`, `tRAS`, etc.) relies on `contextp->timeInc`
  being called with ps-resolution steps. Without Phase 2, `$time` stays near 0 and all timing guards fire
  immediately.

---

## Relevant Files
- `testbench/tb_kv32_soc.sv` — DDR4 block and new mclk generation (lines 286–345)
- `testbench/tb_kv32_soc.cpp` — `main_time`/`time_counter` clock loop (lines 38–50, 640–760)
- `testbench/ddr4_axi4_slave.sv` — new `mclk`/`mresetn` ports and `SIM_MEM_DEPTH` param
- `Makefile` — `VERILATOR_FLAGS` / `VERILATOR_LINT_FLAGS`

## Verification
1. `make MEM_TYPE=ddr4 rtl-hello` — smoke test: must run to completion
2. `make MEM_TYPE=ddr4 WAVE=1 rtl-hello` — inspect waveform; verify `mclk` toggles faster than `clk`
3. `make MEM_TYPE=ddr4-3200 compare-hello` — highest speed grade, async clock stress
4. `make MEM_TYPE=sram compare-all` — SRAM path unchanged

## Decisions
- `mclk` is generated fully inside SV (not exported through the tb module port); C++ only drives `clk`.
- `SIM_MEM_DEPTH=524288` is hardcoded in the DDR4 instantiation (not a Makefile variable).
- `AXI_CLK_PERIOD_NS=10` is hardcoded (clk = core clock = 100 MHz, never varies).
- SRAM path (`axi_memory`) is untouched.
