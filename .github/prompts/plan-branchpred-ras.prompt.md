# Plan: Branch Prediction (BTB+BHT) + Return Address Stack

## Overview

Add configurable branch prediction to the KV32 5-stage pipeline:
- **BTB (Branch Target Buffer)** — IF-stage redirect: when a taken branch's fetch is accepted, advance `pc_if` to the predicted target (not pc_if+4) -> 0-cycle penalty for correctly predicted taken branches
- **BHT (Branch History Table)** — 2-bit saturating counters for direction prediction of conditional branches
- **RAS (Return Address Stack)** — push on any call (JAL/JALR rd!=x0) at EX; pop at IF for returns (any JALR, relaxed convention); predicted return target from BTB
- Parameters exposed at `kv32_core` and `kv32_soc`: BP_EN, BTB_SIZE, BHT_SIZE, RAS_EN, RAS_DEPTH

## Current State (baseline)

| Event | Penalty |
|-------|---------|
| Branch taken | 2 cycles (IF+ID flushed when EX resolves) |
| Branch not-taken | 0 cycles |
| JAL | 2 cycles |
| JALR return | 2 cycles |

With BTB+BHT+RAS:
| Event | Penalty |
|-------|---------|
| Taken, correctly predicted | **0 cycles** |
| Taken, mispredicted | 2 cycles (same as baseline) |
| Not-taken, correctly predicted | 0 cycles |
| Not-taken, mispredicted (predicted taken) | 2 cycles (new cost, BHT limits this) |

## Implementation Plan

### Phase 1 - New predictor modules (independent, can be done in parallel)

**Step 1: `rtl/core/kv32_btb.sv`**
- Parameters: `BTB_SIZE` (default 32, power of 2)
- Direct-mapped cache indexed by `pc[2+$clog2(BTB_SIZE)-1:2]`
- Per entry: `valid(1)`, `tag(31-$clog2(BTB_SIZE) bits)`, `target[31:0]`, `is_return(1)`, `is_uncond(1)` = 36+tag bits
  - `is_return=1`: JALR that should use RAS (any JALR with rd!=x0 per relaxed convention -> actually JALR for returns - see note below)
  - `is_uncond=1`: always-taken (JAL or JALR-as-call - not conditional)
- Read port: combinational, takes `read_pc[31:0]` -> `btb_hit`, `btb_target[31:0]`, `btb_is_return`, `btb_is_uncond`
- Write port: registered, takes `update_en`, `update_pc`, `update_target`, `update_is_return`, `update_is_uncond`
- Determine `is_return` at update: JALR-return = jalr_ex && rd_addr_ex==x0 (relaxed: any JALR is a pop, so JALR with rd==x0 is return-like)
  - Actually: relaxed convention says "pop on any JALR". So BTB type: JAL=JAL; JALR=all JALR with is_return=1 (use RAS if valid); conditional branch = no is_uncond, no is_return

**Step 2: `rtl/core/kv32_bht.sv`**
- Parameters: `BHT_SIZE` (default 64, power of 2)
- 2-bit saturating counters array, indexed by `pc[$clog2(BHT_SIZE)+1:2]`
- Read port: combinational, `read_pc` -> `pred_taken` (counter[1] = strongly/weakly taken)
- Write port: registered, `update_en`, `update_pc`, `actual_taken` (increment if taken, decrement if not)
- Update only for conditional branches (not JAL/JALR): controlled by `update_en` gated externally

**Step 3: `rtl/core/kv32_ras.sv`**
- Parameters: `RAS_DEPTH` (default 8, power of 2)
- Circular LIFO stack using `sp` (stack pointer)
- Push: `push_en` -> store `push_data[31:0]`, increment sp
- Pop: `pop_en` -> decrement sp (top already read combinationally)
- Output: `top[31:0]` = `stack[sp-1]`, `valid` = (sp != 0)
- Non-restoring (no checkpoint/rollback on misprediction - acceptable for simple implementation)
- Note: push and pop can happen in the same cycle (push=call at EX, pop=return at IF). Handle priority: if both asserted, push first then pop (push wins the entry, pop gets previous top).

### Phase 2 - Modify `kv32_core.sv` (*depends on Phase 1*)

**Step 4: Add parameters**

After `FAST_DIV`:
```
parameter bit          BP_EN         = 1'b1,
parameter int unsigned BTB_SIZE      = 32,
parameter int unsigned BHT_SIZE      = 64,
parameter bit          RAS_EN        = 1'b1,
parameter int unsigned RAS_DEPTH     = 8
```

**Step 5: Declare new signals**

```systemverilog
// BTB/BHT outputs (IF stage, read from imem_req_addr_comb)
logic        btb_hit_if, btb_is_return_if, btb_is_uncond_if;
logic [31:0] btb_target_if;
logic        bht_pred_taken_if;

// Combined IF-stage prediction
logic        bp_pred_taken_if;    // prediction: taken
logic [31:0] bp_target_if;        // predicted target (btb or ras)

// Prediction carried through IF/ID pipeline register
logic        bp_pred_taken_id;
logic [31:0] bp_target_id;

// Prediction carried through ID/EX register
logic        bp_taken_ex;
logic [31:0] bp_target_ex;

// EX stage correction signals
logic        bp_correct;          // prediction was right
logic        need_redirect;       // flush + redirect needed (mispred or unpredicted taken)
logic [31:0] bp_redirect_target;  // correct target on redirect

// BTB/BHT update signals
logic        btb_update_en;
logic        btb_update_is_return;
logic        btb_update_is_uncond;
logic        bht_update_en;

// RAS
logic        ras_push_en;
logic [31:0] ras_push_data;
logic        ras_pop_en;
logic [31:0] ras_top;
logic        ras_valid;
```

**Step 6: Instantiate BTB, BHT, RAS** (generate blocks gated by BP_EN/RAS_EN)

BTB reads from `imem_req_addr_comb` (same-cycle combinational, before fetch handshake).
BHT reads from `imem_req_addr_comb`.
RAS is independent (push from EX, pop from IF).

**Step 7: Combined prediction logic**

```systemverilog
assign bp_pred_taken_if = BP_EN && btb_hit_if && (
    btb_is_uncond_if ||
    (btb_is_return_if && RAS_EN && ras_valid) ||
    (!btb_is_uncond_if && !btb_is_return_if && bht_pred_taken_if)
);
assign bp_target_if = (BP_EN && btb_is_return_if && RAS_EN && ras_valid)
                        ? ras_top : btb_target_if;
```

**Step 8: Modify `pc_if` update (in the existing `always_ff` block)**

Inside the `branch_taken && !branch_flushed` case: keep as-is (this fires when unpredicted).
Inside the sequential `imem_req_ready && imem_req_valid` sub-case, change:
```
// Before: pc_if <= imem_req_addr + 32'd4;
// After:
if (BP_EN && bp_pred_taken_if && !non_branch_flush)
    pc_if <= {bp_target_if[31:2], 2'b00};
else
    pc_if <= imem_req_addr + 32'd4;
```

**Step 9: Carry prediction through IF/ID register**

In the IF/ID `always_ff` block, in the `!if_id_stall && if_valid` branch, add:
```
bp_pred_taken_id <= bp_pred_taken_if;
bp_target_id     <= bp_target_if;
```
In the flush/reset/stall/bubble branches, set `bp_pred_taken_id <= 1'b0`.

**Step 10: Carry prediction through ID/EX register**

In the ID/EX `always_ff` block, in the normal advance branch, add:
```
bp_taken_ex  <= bp_pred_taken_id;
bp_target_ex <= bp_target_id;
```
In flush/reset/bubble branches, set `bp_taken_ex <= 1'b0`.

**Step 11: EX-stage correction logic**

```systemverilog
assign bp_correct = bp_taken_ex && branch_taken && ex_valid &&
                    (bp_target_ex == branch_target);

// need_redirect: must flush. Fires when:
//   a) branch taken without correct prediction
//   b) incorrectly predicted taken (but branch not taken)
assign need_redirect = ex_valid && !branch_flushed &&
                       (branch_taken || bp_taken_ex) && !bp_correct && !is_mret_ex;

assign bp_redirect_target = branch_taken ? branch_target
                           : (pc_ex + (is_compressed_ex ? 32'd2 : 32'd4));
```

Note: `need_redirect` replaces the role of `(branch_taken && !branch_flushed)` in flush signals.

**Step 12: Update `if_flush`, `id_flush` and `if_flush_pc`**

Replace `(branch_taken && !branch_flushed)` with `need_redirect`:
```systemverilog
assign if_flush = need_redirect || exception || wb_exception || irq_pending
                  || is_mret_ex || fence_i_flush || cbo_flush || wfi_branch;
assign id_flush = need_redirect || exception || wb_exception || irq_pending
                  || is_mret_ex || wfi_branch;
```

Update `if_flush_pc` priority chain - replace the `branch_taken && !branch_flushed` line with:
```systemverilog
need_redirect ? bp_redirect_target :
```
(higher priority than fence_i/cbo but lower than exception/irq/mret/wfi)

**Step 13: Update `branch_flushed` register**

Replace condition `branch_taken && !branch_flushed` with `need_redirect`, reset condition unchanged:
```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        branch_flushed <= 1'b0;
    else if (need_redirect && !branch_flushed)
        branch_flushed <= 1'b1;
    else if (!id_ex_stall && !downstream_stall && !load_use_hazard)
        branch_flushed <= 1'b0;
end
```

**Step 14: BTB/BHT update logic (EX stage)**

```systemverilog
// Update BTB for any branch/JAL/JALR that resolves at EX
assign btb_update_en       = (branch_ex || jal_ex || jalr_ex) && ex_valid && !ex_flush;
assign btb_update_is_uncond = jal_ex || jalr_ex;
assign btb_update_is_return = jalr_ex;  // relaxed: all JALR = returns (use RAS)

// Update BHT only for conditional branches
assign bht_update_en = branch_ex && ex_valid && !ex_flush;
// actual_taken for BHT:
wire bht_actual_taken = branch_taken && !is_mret_ex;
```

**Step 15: RAS push/pop logic**

```systemverilog
// Push at EX stage (confirmed call: JAL/JALR with rd != x0)
assign ras_push_en   = RAS_EN && (jal_ex || jalr_ex) && (rd_addr_ex != 5'd0)
                        && ex_valid && !ex_flush;
assign ras_push_data = pc_ex + (is_compressed_ex ? 32'd2 : 32'd4);

// Pop at IF stage (any JALR: relaxed convention) - when BTB says it's a return AND we predict taken
assign ras_pop_en = RAS_EN && BP_EN && btb_hit_if && btb_is_return_if && ras_valid
                    && imem_req_valid && imem_req_ready && !non_branch_flush;
```

**Step 16: Add debug messages** (wrapped in `` `DEBUG2 ``)

```systemverilog
`DEBUG2(`DBG_GRP_EX, ("[BP] Prediction: pc_ex=0x%h taken=%b pred_taken=%b pred_target=0x%h correct=%b",
        pc_ex, branch_taken, bp_taken_ex, bp_target_ex, bp_correct));
`DEBUG2(`DBG_GRP_EX, ("[BP] Mispred: pc_ex=0x%h redirect=0x%h", pc_ex, bp_redirect_target));
```

Add a new debug group bit for BP (e.g., Bit 19 = 0x80000) in kv32_pkg.sv or the debug macros.

### Phase 3 - Modify `kv32_soc.sv` (*depends on Phase 2*)

**Step 17: Add parameters** (after `FAST_DIV`):
```
parameter bit          BP_EN         = 1'b1,
parameter int unsigned BTB_SIZE      = 32,
parameter int unsigned BHT_SIZE      = 64,
parameter bit          RAS_EN        = 1'b1,
parameter int unsigned RAS_DEPTH     = 8,
```

**Step 18: Pass parameters** (in `kv32_core` instantiation):
```
.BP_EN(BP_EN), .BTB_SIZE(BTB_SIZE), .BHT_SIZE(BHT_SIZE),
.RAS_EN(RAS_EN), .RAS_DEPTH(RAS_DEPTH),
```

### Phase 4 - Verification

**Step 19:** Run existing regression suite with BP_EN=1, RAS_EN=1 (default):
```
make compare-hello && make compare-simple && make compare-full &&
make compare-interrupt && make compare-uart && make compare-freertos-simple
```

**Step 20:** Test with both features disabled (regression-stable baseline):
```
make compare-hello BP_ARGS="-pBP_EN=0 -pRAS_EN=0"   # if make supports param override
```
Or edit kv32_soc.sv to set BP_EN=0, RAS_EN=0, run suite.

**Step 21:** Verify 0-cycle penalty with instruction trace on a loop-heavy program:
```
make TRACE=1 rtl-dhry && make TRACE=1 sim-dhry
make compare-dhry
```
Check trace output for correct instruction retirement order.

**Step 22:** Waveform inspection of BTB hit/miss, RAS push/pop, misprediction flush:
```
make WAVE=1 rtl-simple
```
Inspect `btb_hit_if`, `bp_pred_taken_if`, `need_redirect`, `branch_flushed`, `ras_push_en`, `ras_pop_en`.

---

## Relevant Files

- [rtl/core/kv32_core.sv](rtl/core/kv32_core.sv) - main core: add parameters, instantiate predictors, modify `pc_if` update, flush signals, pipeline registers
- [rtl/core/kv32_ib.sv](rtl/core/kv32_ib.sv) - IB: **no changes needed** (prediction carried independently)
- [rtl/core/kv32_rvc.sv](rtl/core/kv32_rvc.sv) - RVC: **no changes needed**
- [rtl/kv32_soc.sv](rtl/kv32_soc.sv) - SoC: add/pass BP_EN, BTB_SIZE, BHT_SIZE, RAS_EN, RAS_DEPTH
- New: `rtl/core/kv32_btb.sv`, `rtl/core/kv32_bht.sv`, `rtl/core/kv32_ras.sv`

## Decisions

- **Predictor type**: BTB+BHT at IF stage (user chose)
- **RAS convention**: Relaxed - push on JAL/JALR with rd!=x0; pop on any JALR (BTB marks all JALR as `is_return`)
- **RAS timing**: Push at EX (confirmed call), pop at IF (predicted return) - no checkpoint/restore
- **BTB lookup at ID**: Re-read BTB at ID stage using `pc_id` to get prediction metadata for EX validation
- **`branch_flushed`**: Extended to cover `need_redirect` (both unpredicted-taken and mispredicted-taken)
- **Debug group**: Add DBG_GRP_BP (Bit 19 = 0x80000) for branch predictor debug messages
- **Excluded**: GShare (global history XOR), BTB way-associativity, RAS checkpoint - not needed for initial implementation
