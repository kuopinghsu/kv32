# Plan: Hardware ISA Extension — Stack Guard + SP Watermark CSRs

## Overview

Add two custom machine-mode CSRs to KV32 so hardware can enforce a programmable stack lower bound and record the minimum stack pointer ever observed. The implementation should add the CSR definitions and exception cause in the core RTL and simulator first, then integrate the CSRs into the RTOS context-switch path so each task gets its own guard and watermark state. Validation should include both a standalone stack-guard test and an RTOS-level watermark regression.

---

## CSR Map

| Addr  | Name         | R/W | Description |
|-------|--------------|-----|-------------|
| 0x7CC | SGUARD_BASE  | R/W | Stack guard lower bound. Hardware raises exception cause 16 when x2 is written with a value below this register. Write 0 to disable. |
| 0x7CD | SPMIN        | R/W | Minimum SP value written since last software reset. Hardware updates to `min(current, new_sp)` on every x2 write. Software may reset it by writing `0xFFFF_FFFF`. |

### Exception Definition

| Cause | Name                  | Meaning |
|-------|-----------------------|---------|
| 16    | EXC_STACK_OVERFLOW    | SP write attempted below `SGUARD_BASE`; `mtval` holds the attempted SP value; bad SP is not architecturally committed. |

---

## Phase 1 — ISA Definitions

### Step 1 — `rtl/core/kv32_pkg.sv`

Add the two new CSR addresses after `CSR_PMAADDR7`:

```systemverilog
CSR_SGUARD_BASE = 12'h7CC,
CSR_SPMIN       = 12'h7CD
```

Add a custom exception cause:

```systemverilog
EXC_STACK_OVERFLOW = 5'd16
```

### Step 2 — `sim/kv32sim.h`

Add matching simulator constants:

```c
#define CSR_SGUARD_BASE 0x7CC
#define CSR_SPMIN       0x7CD
#define CAUSE_STACK_OVERFLOW 16
```

Add simulator state fields:

```c
uint32_t csr_sguard_base;
uint32_t csr_spmin;
```

---

## Phase 2 — RTL Changes

### Step 3 — `rtl/core/kv32_csr.sv`

Add registers:

```systemverilog
logic [31:0] sguard_base_r;
logic [31:0] spmin_r;
```

Add ports:
- output `sguard_base_o[31:0]`
- input `sp_we_i`
- input `sp_wdata_i[31:0]`

Behavior:
- `CSR_SGUARD_BASE` is software-readable and software-writeable
- `CSR_SPMIN` is software-readable and software-writeable
- On any SP writeback pulse, hardware updates `spmin_r` if `sp_wdata_i < spmin_r`
- If software writes `CSR_SPMIN` in the same cycle, software write wins
- Reset state: `sguard_base_r = 0`, `spmin_r = 32'hFFFF_FFFF`

Add both CSRs to the legal CSR decode chain.

### Step 4 — `rtl/core/kv32_decoder.sv`

Add `CSR_SGUARD_BASE` and `CSR_SPMIN` to the SYSTEM/CSR legal-address whitelist.

### Step 5 — `rtl/core/kv32_core.sv`

Add EX-stage overflow detection for any instruction that writes x2:

```systemverilog
stack_overflow_ex = reg_we_ex && (rd_addr_ex == 5'd2) &&
                    (sguard_base != 32'b0) &&
                    (alu_result_ex < sguard_base);
```

Propagate this condition through the pipeline to the exception-priority logic.

In the exception chain, insert:

```systemverilog
else if (stack_overflow_ex_mem) begin
    exception       = 1'b1;
    exception_cause = EXC_STACK_OVERFLOW;
    exception_tval  = alu_result_mem;
end
```

Generate a CSR-side SP write pulse from WB:

```systemverilog
sp_we_o    = reg_we_wb && retire_instr && (rd_addr_wb == 5'd2);
sp_wdata_o = wb_write_data;
```

Wire `sguard_base_o` from CSR into the EX-stage comparison path.

---

## Phase 3 — Software Simulator

### Step 6 — `sim/kv32sim.cpp`

Extend `read_csr()`:
- `CSR_SGUARD_BASE` returns `csr_sguard_base`
- `CSR_SPMIN` returns `csr_spmin`

Extend `write_csr()`:
- `CSR_SGUARD_BASE` updates `csr_sguard_base`
- `CSR_SPMIN` updates `csr_spmin`

Reset/init behavior:
- `csr_sguard_base = 0`
- `csr_spmin = 0xFFFF_FFFF`

After any instruction writes x2:
1. Update `csr_spmin` if the new SP is smaller
2. If `csr_sguard_base != 0` and the new SP is below the guard, take trap cause 16 with `mtval = new_sp`
3. Match RTL semantics by treating the event as a stack-overflow trap condition rather than a generic access fault

Also update any CSR trace name tables to include the new CSR names.

---

## Phase 4 — RTOS Integration

### Step 7 — `sw/rtos/mrtos.h`

Add TCB fields:

```c
uint32_t sguard_base;
uint32_t stack_top_addr;
uint32_t spmin_saved;
```

Add public API:

```c
uint32_t mrtos_stack_watermark(const mrtos_tcb_t *tcb);
```

This API returns peak stack usage in bytes:

```c
tcb->stack_top_addr - tcb->spmin_saved
```

### Step 8 — `sw/rtos/mrtos_core.c`

In `mrtos_task_create()` initialize:
- `sguard_base` to the base of the task stack
- `stack_top_addr` to stack base plus stack size
- `spmin_saved` to `stack_top_addr`

In the scheduler path where both outgoing and incoming tasks are known:
- save outgoing `spmin_saved = read_csr_spmin()`
- restore incoming `write_csr_sguard_base(next->sguard_base)`
- restore incoming `write_csr_spmin(next->spmin_saved)`

Implement:

```c
uint32_t mrtos_stack_watermark(const mrtos_tcb_t *tcb)
```

so it reports the max observed stack consumption.

---

## Phase 5 — Standalone Test

### Step 9 — `sw/stack_guard/` test

Create a dedicated bare-metal test with a recursion-based workload and a custom trap handler.

Required subtests:
1. Guard disabled: recurse deeply, verify no overflow trap, verify `SPMIN` records a low-water mark
2. Guard enabled with margin: recurse shallowly, verify no trap and a sensible watermark
3. Guard enabled tightly: recurse until SP crosses below the programmed bound, verify cause 16 trap fires
4. `SPMIN` reset: write `0xFFFF_FFFF`, recurse again, verify hardware lowers the watermark anew

The trap handler should confirm:
- `mcause == 16`
- `mtval` equals the attempted bad SP value
- execution resumes or exits in a controlled PASS/FAIL path

### Step 10 — `Makefile`

Add `sim-stack_guard`, `rtl-stack_guard`, and `compare-stack_guard` targets following the pattern of existing software tests.

---

## Phase 6 — RTOS Regression Test

### Step 11 — `sw/rtos/rtos_test.c`

Add a new RTOS test that creates two tasks with different recursion depths or stack demands and verifies:
- both tasks run correctly under scheduler control
- `mrtos_stack_watermark()` reports a larger peak usage for the deeper task
- the per-task save/restore path preserves watermark accounting across context switches

---

## Relevant Files

- `rtl/core/kv32_pkg.sv`
- `rtl/core/kv32_csr.sv`
- `rtl/core/kv32_decoder.sv`
- `rtl/core/kv32_core.sv`
- `sim/kv32sim.h`
- `sim/kv32sim.cpp`
- `sw/rtos/mrtos.h`
- `sw/rtos/mrtos_core.c`
- `sw/rtos/rtos_test.c`
- `sw/stack_guard/` (new)
- `Makefile`

---

## Verification Checklist

- [ ] `make sim-stack_guard` passes all standalone subtests
- [ ] `make rtl-stack_guard` reproduces the same behavior on RTL
- [ ] `make compare-stack_guard` shows no RTL vs simulator divergence
- [ ] `make sim-rtos` passes with the new watermark regression
- [ ] `make rtl-rtos` passes with the new watermark regression
- [ ] `make compare-rtos` shows no divergence introduced by per-task CSR save/restore

---

## Decisions

- `SGUARD_BASE == 0` disables checking
- `SPMIN` is both software-writeable and hardware-tightened
- exception cause 16 is used as a KV32 custom exception
- `mtval` records the attempted out-of-bounds SP value
- overflow is detected before the bad SP becomes architecturally visible
- RTOS save/restore is done in C scheduler logic where both old and new tasks are visible
