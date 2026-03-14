# KV32 Branch Prediction and Return Address Architecture

## Document Purpose

This document describes the architectural design and implementation details of KV32 branch prediction and return address handling. It is based on the implementation in:

- `rtl/core/kv32_core.sv`
- `rtl/core/kv32_btb.sv`
- `rtl/core/kv32_bht.sv`
- `rtl/core/kv32_ras.sv`
- `rtl/kv32_soc.sv`

It also references the implementation plan in:

- `docs/plan-branchpred-ras.prompt.md`

This document includes the design analysis comparing IF-stage prediction and ID-stage prediction, including measured branch alignment data from `build/hello.dis`.

---

## 1. High-Level Goals

The branch prediction subsystem is designed to:

1. Reduce control-hazard penalty versus classic EX-only redirect.
2. Keep implementation small and robust for an embedded RV32IMAC core.
3. Correctly support compressed instructions (RVC) without fetch alignment bugs.
4. Improve return prediction via a Return Address Stack (RAS).
5. Preserve deterministic recovery on misprediction or exception.

### 1.1 Configurable Parameters

At core and SoC level, the following parameters are exposed:

- `BP_EN` (default `1`): global branch predictor enable
- `BTB_SIZE` (default `32`): BTB direct-mapped entries
- `BHT_SIZE` (default `64`): BHT 2-bit counter entries
- `RAS_EN` (default `1`): return address stack enable
- `RAS_DEPTH` (default `8`): RAS depth

These are defined in:

- `rtl/core/kv32_core.sv`
- `rtl/kv32_soc.sv`

---

## 2. Architectural Summary

KV32 implements a hybrid predictor structure:

1. **BTB** for target and instruction class metadata.
2. **BHT** for conditional branch direction prediction.
3. **RAS** for return target prediction.

### 2.1 Important Design Decision

Although the original plan discusses IF-stage prediction, the implemented design performs prediction at **ID stage** using `pc_id`.

Reason:

- KV32 supports RVC and executes at halfword granularity.
- IF fetches are word-granular.
- Predicting purely from fetch address creates ambiguity for instructions at `PC[1]=1` and can introduce RVC offset/flush correctness issues.

The implemented ID-stage approach avoids this hazard while still cutting branch penalty significantly versus EX-only redirect.

### 2.2 Quick Decision Matrix

| Option | Correctly predicted taken penalty | RVC branch coverage | Complexity impact | Recommended use |
|---|---|---|---|---|
| EX-only redirect | 2 cycles | 100% | Lowest | Baseline reference only |
| ID-stage predictor (current) | 1 cycle | 100% | Low-to-moderate | Current KV32 default |
| IF-stage only (single-lane) | 0 cycles | About 50% | Moderate-to-high | Not recommended alone in RVC-heavy workloads |
| IF+ID hybrid | 0 or 1 cycle | 100% | Highest | Future performance-focused option |

---

## 3. Predictor Microarchitecture

## 3.1 BTB (`kv32_btb.sv`)

### Organization

- Direct-mapped table with `BTB_SIZE` entries.
- Entry fields:
  - `valid`
  - `tag`
  - `target`
  - `is_return`
  - `is_uncond`

### Addressing

BTB index uses halfword granularity:

- `read_idx = read_pc[INDEX_W:1]`
- `update_idx = update_pc[INDEX_W:1]`

This is intentional so addresses `0x...0` and `0x...2` map to different entries.

### Interfaces

- Combinational read: `read_pc -> hit/target/is_return/is_uncond`
- Registered update on `update_en`

### Metadata policy

- `is_uncond = 1` for JAL/JALR-class unconditional flow changes.
- `is_return = 1` for JALR return-class use by predictor policy (relaxed convention in implementation flow).

## 3.2 BHT (`kv32_bht.sv`)

### Organization

- `BHT_SIZE` entries of 2-bit saturating counters.
- Reset value: `2'b01` (weakly not-taken).

### Addressing

- Halfword granularity index: `read_pc[INDEX_W:1]`, `update_pc[INDEX_W:1]`.

### Prediction rule

- `pred_taken = counter[1]`

### Update rule

- Increment on taken (saturate at `11`)
- Decrement on not-taken (saturate at `00`)
- Updated only for conditional branches (`branch_ex`).

## 3.3 RAS (`kv32_ras.sv`)

### Organization

- Stack array with `RAS_DEPTH` entries.
- Validity derived from `count != 0`.
- Combinational `top` output from `count-1`.

### Push/Pop behavior

- Push on confirmed call-class instruction in EX (`jal_ex || jalr_ex`) with `rd != x0`.
- Pop when return prediction is consumed.

### Simultaneous push+pop

When both are asserted in one cycle, logic preserves depth and replaces top with pushed value (count unchanged when stack non-empty), equivalent to atomic pop+push behavior appropriate for pipeline overlap scenarios.

---

## 4. Pipeline Integration in `kv32_core.sv`

## 4.1 Stage Placement

Prediction decision is computed in ID stage:

- BTB read uses `pc_id`
- BHT read uses `pc_id`
- Instruction class gate uses decoded `jal_id`, `jalr_id`, `branch_id`

Combined taken decision:

- BTB hit required
- If unconditional: predict taken
- If return: require valid RAS and use RAS top
- If conditional: use BHT taken state

Combined target:

- RAS top for return-class prediction
- Otherwise BTB target

## 4.2 Redirect mechanism

On ID-stage taken prediction:

- `bp_if_flush` pulses when prediction is valid and front-end can advance.
- IF is flushed and redirected to `bp_target_id`.
- RVC expander receives flush PC and resets halfword offset state correctly via `if_flush_pc[1]`.

Guarding conditions intentionally avoid firing prediction flush during stalls:

- `bp_if_flush = bp_pred_taken_id && !id_flush && !if_id_stall`

## 4.3 EX-stage correction

EX computes actual branch/jump outcome and target (`branch_taken`, `branch_target`) and compares with carried prediction state:

- `bp_taken_ex`
- `bp_target_ex`

A redirect is required when:

- Branch/jump is taken but prediction is absent/wrong, or
- Prediction says taken but actual falls through.

This is abstracted as `need_redirect`.

Redirect target selection:

- If actually taken: `branch_target`
- If predicted-taken but actually not taken: sequential `pc_ex + (2 or 4)` based on compressed instruction size.

## 4.4 Flush integration

`if_flush` includes both:

- `need_redirect` (EX correction), and
- `bp_if_flush` (ID prediction redirect)

This ensures:

1. Early redirect on predicted taken branches.
2. Precise correction for misprediction.
3. Correct interaction with exception/interrupt/mret/fence/cbo/wfi flush causes.

`if_flush_pc` priority chain includes branch predictor redirection in explicit order relative to other architectural redirect sources.

## 4.5 Branch-flush one-shot control

`branch_flushed` is retained and generalized to `need_redirect` to prevent repeated reflush while EX is stalled on the same control-flow instruction.

---

## 5. Detailed Control Signal Intent

### 5.1 Prediction path signals

- `btb_hit_id`, `btb_target_id`, `btb_is_return_id`, `btb_is_uncond_id`
- `bht_pred_taken_id`
- `bp_pred_taken_id`, `bp_target_id`
- `bp_if_flush`

### 5.2 Correction path signals

- `bp_taken_ex`, `bp_target_ex`
- `bp_correct`
- `need_redirect`
- `bp_redirect_target`

### 5.3 Update path signals

- `btb_update_en`, `btb_update_is_return`, `btb_update_is_uncond`
- `bht_update_en`, `bht_actual_taken`

### 5.4 RAS signals

- `ras_push_en`, `ras_push_data`
- `ras_pop_en`
- `ras_top`, `ras_valid`

### 5.5 Signal Glossary (Fast Lookup)

| Signal | Stage | Meaning |
|---|---|---|
| `bp_pred_taken_id` | ID | Combined taken decision from BTB/BHT/RAS for current decoded control-flow instruction |
| `bp_target_id` | ID | Predicted target address used for early redirect when `bp_if_flush` fires |
| `bp_if_flush` | ID->IF | One-shot front-end redirect pulse for ID-stage taken prediction |
| `bp_taken_ex` | EX | Prediction-taken metadata carried with instruction for correctness check |
| `bp_target_ex` | EX | Predicted target metadata carried to EX |
| `bp_correct` | EX | Asserted when predicted taken and target both match resolved outcome |
| `need_redirect` | EX->IF/ID | Corrective redirect request for unpredicted taken or mispredicted taken |
| `bp_redirect_target` | EX | Correct target on redirect (actual target or sequential fall-through) |
| `btb_update_en` | EX | BTB update enable for branch/JAL/JALR resolution |
| `bht_update_en` | EX | BHT update enable for conditional branches |
| `ras_push_en` | EX | Push return address on confirmed call-class instruction |
| `ras_pop_en` | ID | Pop RAS when return-class prediction is accepted |

---

## 6. RVC Interaction and Why It Matters

KV32 executes compressed and uncompressed instructions with halfword-granular PC progression. However, memory fetch and icache interfaces are word-granular. This creates two classes of control-flow instruction addresses:

- `PC[1]=0` (lower halfword of aligned word)
- `PC[1]=1` (upper halfword of aligned word)

For `PC[1]=1`, the branch instruction is not available as an independent IF-stage object without additional dual-lane decode/predict machinery. The RVC expander and fetch buffering must resolve halfword sequencing first.

ID-stage prediction naturally eliminates this ambiguity because `pc_id` corresponds to the exact decoded instruction boundary.

---

## 7. IF-stage vs ID-stage prediction: Performance vs Complexity

This section records the requested analysis and measured data.

## 7.1 Cycle-by-cycle comparison (clear timeline)

For a correctly predicted taken branch, the practical timeline is:

### Table comparison by cycle

| Cycle | Current ID-stage prediction | IF-stage prediction (idealized) |
|---|---|---|
| N | branch at IF | branch at IF, BTB hit, `pc_if` redirected to target same cycle |
| N+1 | branch at ID, `bp_if_flush` fires, fallthrough IF killed, target fetch starts | branch at ID, target fetch accepted |
| N+2 | branch at EX, bubble at ID | branch at EX, target at IF/ID |
| N+3 | branch at MEM, target at ID | branch at MEM, target at ID |

### Step flow (ID-stage prediction)

```text
Step 1: IF sees branch
  -> Step 2: ID resolves predictor metadata and asserts bp_if_flush
  -> Step 3: Front-end redirects to target, one slot is lost
  -> Step 4: EX verifies predicted target/direction
```

### Step flow (IF-stage prediction, idealized)

```text
Step 1: IF sees branch and BTB hits immediately
  -> Step 2: PC redirects in same cycle
  -> Step 3: Target stream is fetched without the extra ID-stage redirect bubble
  -> Step 4: EX still validates and corrects if needed
```

Conclusion from timeline:

- ID-stage: usually one lost slot for correctly predicted taken branches.
- IF-stage: can remove that slot for eligible branches.

## 7.2 Idealized penalty model

Let taken branch prediction be correct.

- EX-only redirect baseline: typically 2-cycle wrong-path penalty in this pipeline class.
- ID-stage prediction (current): 1-cycle bubble equivalent for predicted-taken path.
- IF-stage prediction (ideal): 0-cycle penalty for eligible branches.

Therefore, IF-stage can save up to 1 extra cycle over ID-stage for a correctly predicted taken branch.

## 7.3 Eligibility limit with RVC

Measured on `build/hello.dis`:

- Total branch/jump instructions counted: `2184`
- 4-byte aligned (`PC[1]=0`): `1087` (`49.8%`)
- Halfword offset (`PC[1]=1`): `1097` (`50.2%`)

Implication:

- A single-lane IF-stage predictor can only directly help the `PC[1]=0` subset.
- About half of branches still need ID-stage handling unless front-end complexity is expanded substantially.

## 7.4 Why IF-stage is not automatically best in KV32

To fully exploit IF-stage with RVC, the front end would need at least:

1. Dual BTB/BHT lookup capability (for both halfword lanes per fetch word), or equivalent lane-aware predictor.
2. Careful synchronization with RVC `init_offset`/flush behavior to avoid killing or duplicating instructions.
3. Additional handling for already-buffered/discarded fetch responses in IB.
4. A hybrid fallback path for branch instructions that are not lane-0 eligible.

Area and complexity increase materially, while net gain is bounded.

## 7.5 Quantitative intuition

If `f_taken` is taken ratio and `f_lane0` is fraction at `PC[1]=0`, extra gain of IF over ID is roughly:

`Delta_CPI ~= -1 * f_taken * f_lane0 * f_pred_correct`

With `f_lane0 ~ 0.5`, IF-stage can only harvest about half of the theoretical one-cycle benefit unless the predictor becomes lane-aware for both halfwords.

## 7.6 Net benefit estimate

This table summarizes expected control-hazard penalty by predictor strategy in KV32.

| Prediction strategy | Correctly predicted taken penalty | Coverage in RVC system | Notes |
|---|---|---|---|
| No dynamic predictor (EX redirect only) | 2 cycles | 100% | Baseline branch/jump correction in EX |
| Current ID-stage predictor | 1 cycle | 100% | Uniform behavior for both `PC[1]=0` and `PC[1]=1` |
| IF-stage predictor only (single-lane) | 0 cycles | About 50% | Primarily lane-0 (`PC[1]=0`) branches |
| IF+ID hybrid predictor | 0 or 1 cycle | 100% | IF fast path plus ID fallback |

Expected incremental gain of IF over current ID-stage can be approximated as:

`Delta_CPI(ID->IF) ~= -1 * f_taken * f_lane0 * f_pred_correct`

Where:

- `f_taken`: fraction of dynamic control-flow instructions that are taken
- `f_lane0`: fraction of predicted control-flow at `PC[1]=0`
- `f_pred_correct`: predictor correctness on this subset

Using measured lane split from `hello.dis`:

- `f_lane0 ~= 0.498`

Example sensitivity (illustrative):

| `f_taken` | `f_pred_correct` | Estimated `Delta_CPI(ID->IF)` |
|---|---|---|
| 0.60 | 0.90 | `-0.269` |
| 0.50 | 0.85 | `-0.212` |
| 0.40 | 0.80 | `-0.159` |

Interpretation:

- IF-stage can reduce CPI versus ID-stage, but only on the lane-0-eligible subset unless the front-end is upgraded to lane-aware dual-path prediction.
- Therefore, in current KV32 constraints, ID-stage remains the better complexity/performance balance.

## 7.7 Assumptions and Limits of the Estimate

The net-benefit estimates in this section are first-order guidance, not full measured CPI projections.

Assumptions used:

- Branch penalty model uses idealized per-branch slot loss (2/1/0 cycles depending on strategy).
- `f_taken` and `f_pred_correct` are workload-dependent and can vary significantly across programs.
- `f_lane0` is taken from one measured disassembly snapshot (`hello.dis`), not all workloads.
- Memory-system effects, fetch backpressure, and cache-miss overlap are not modeled in the simple formula.

Recommended practice:

1. Use this model for architectural direction and tradeoff screening.
2. Use trace/perf-counter runs for workload-specific signoff.

---

## 8. Plan Reference and Implementation Mapping

The reference plan is `docs/plan-branchpred-ras.prompt.md`.

### 8.1 What matches the plan

- BTB/BHT/RAS modules added.
- Core and SoC parameters exposed.
- EX correction and redirect architecture implemented.
- BTB/BHT update and RAS push/pop behavior implemented.
- Debug group for predictor exists (`DBG_GRP_BP`).

### 8.2 Intentional divergence

The largest divergence is predictor placement:

- Plan narrative emphasizes IF-stage predictor timing.
- Actual implementation uses ID-stage prediction to preserve correctness and simplicity with RVC halfword flow.

This is an intentional architectural tradeoff, not a missing feature.

---

## 9. Debug and Observability

Branch predictor debug support is integrated via debug groups:

- `DBG_GRP_BP` in `kv32_pkg.sv` (bit index 19)
- Redirect/mispredict traces include predicted-vs-actual details

Typical useful signals for waveform/debug:

- `btb_hit_id`
- `bht_pred_taken_id`
- `bp_pred_taken_id`
- `bp_if_flush`
- `need_redirect`
- `bp_redirect_target`
- `branch_flushed`
- `ras_push_en`
- `ras_pop_en`
- `ras_top`

---

## 10. Verification Status (Current)

Based on executed regressions in this workstream:

- Baseline compare tests passed with predictor defaults enabled.
- RTOS asymmetric latency stress scenarios passed after test scaling update.
- Plan checklist review indicates all functional implementation steps complete; waveform inspection remains an optional manual step.

Recommended continuing checks:

1. Compare performance counters with `BP_EN=1` versus `BP_EN=0` on branch-heavy workloads.
2. Use trace comparison on loop-heavy programs to validate no retirement-order regressions.
3. Optional waveform review focused on redirect and RAS corner timing.

### 10.1 Runnable Command Set

Use these commands for reproducible verification:

```bash
make compare-hello && make compare-simple && make compare-full && make compare-interrupt && make compare-uart && make compare-freertos-simple
```

```bash
make compare-hello BP_EN=0 RAS_EN=0
```

```bash
make TRACE=1 rtl-dhry && make TRACE=1 sim-dhry && make compare-dhry
```

```bash
make WAVE=1 rtl-simple
```

Waveform signals to inspect:

- `btb_hit_id`, `bht_pred_taken_id`, `bp_pred_taken_id`
- `bp_if_flush`, `need_redirect`, `bp_redirect_target`
- `branch_flushed`, `ras_push_en`, `ras_pop_en`, `ras_top`

---

## 11. Tradeoff Summary

### Current architecture strengths

- Correct under RVC halfword sequencing.
- Moderate complexity, low area.
- Clear interaction with existing flush/exception framework.
- Good branch penalty reduction versus no prediction.

### Current architecture limits

- Does not achieve full 0-cycle predicted-taken behavior in all cases.
- Leaves potential performance on table for lane-0-aligned branch population.

### Future direction (if higher performance is required)

Implement a hybrid IF+ID predictor:

- IF-stage prediction for lane-0 eligible branches (fast path),
- ID-stage prediction as universal fallback,
- predictor and front-end lane awareness for RVC correctness.

This is the safest path to increase performance without sacrificing correctness.

### Final Recommendation

For current KV32 goals and constraints, keep ID-stage prediction as the production architecture:

- It delivers robust branch penalty reduction with full RVC coverage.
- It avoids IF-stage lane-complexity and front-end corner-case risk.
- It keeps a clear migration path to IF+ID hybrid if future performance targets justify added complexity.

---

## 12. Quick Reference

### Source files

- `rtl/core/kv32_core.sv`: integration, flush/redirect control, updates
- `rtl/core/kv32_btb.sv`: target + type predictor
- `rtl/core/kv32_bht.sv`: direction predictor
- `rtl/core/kv32_ras.sv`: return stack
- `rtl/kv32_soc.sv`: top-level parameter exposure
- `rtl/core/kv32_pkg.sv`: debug group declaration

### Plan file

- `docs/plan-branchpred-ras.prompt.md`

### Related architecture doc

- `docs/pipeline_architecture.md`

---

## 13. Cycle-by-Cycle Behavioral Scenarios

This section captures the most important dynamic behaviors in the current implementation.

### 13.1 Correctly Predicted Taken Conditional Branch

For the side-by-side timeline comparison, see Section 7.1.

This section focuses on implementation corner behavior and recovery details not emphasized in the comparison table.

### 13.2 Predicted Taken but Actually Not Taken

1. Cycle N: ID predicts taken, `bp_if_flush` redirects fetch.
2. Later in EX: branch resolves not taken.
3. `need_redirect=1` because prediction is wrong.
4. `bp_redirect_target = pc_ex + (is_compressed_ex ? 2 : 4)`.
5. IF/ID are flushed once; fetch restarts at sequential fall-through.

### 13.3 Unpredicted Taken Branch

1. Cycle N: branch in ID but either BTB miss or BHT not-taken -> no early redirect.
2. Cycle N+1/N+2: branch resolves taken in EX.
3. `need_redirect=1`, `bp_redirect_target=branch_target`.
4. Front-end flush and redirect occur from EX.

### 13.4 Return Prediction Using RAS

Return path relies on BTB classifying return and RAS being non-empty.

1. Call-class instruction in EX (`jal_ex || jalr_ex`) with `rd!=x0`:
  - `ras_push_en=1`
  - pushed value is return PC (`pc_ex + 2/4`).
2. Later return-class instruction reaches ID:
  - BTB indicates return-class metadata.
  - If `ras_valid=1`, target source is `ras_top`.
3. Prediction acceptance (`bp_if_flush=1`) triggers `ras_pop_en=1`.

If RAS is empty (`ras_valid=0`), return prediction does not use RAS target and EX correction still guarantees architectural correctness.

### 13.5 Simultaneous Push and Pop in RAS

When push and pop assert together (`2'b11` case in `kv32_ras.sv`):

- If stack empty: write entry 0 and set count to 1.
- If stack non-empty: overwrite current top with `push_data`, keep depth unchanged.

This avoids count oscillation and supports overlapped call/return traffic in pipeline timing.

### 13.6 Predictor and Non-Branch Flush Priority

`if_flush_pc` priority in `kv32_core.sv` ensures precise control transfer ordering:

1. Debug PC write (halted)
2. Trap/exception/interrupt vector (`mtvec`)
3. MRET (`mepc`)
4. WFI branch hold
5. EX corrective redirect (`need_redirect`)
6. ID prediction redirect (`bp_if_flush`)
7. Fence/CBO replay path (`pc_mem + 4`)
8. Reset/default base

This ordering prevents predictor redirects from overriding higher-priority architectural redirects.

---

## 14. Plan-Step Traceability Matrix

Reference plan: `docs/plan-branchpred-ras.prompt.md`.

Status legend:

- Implemented: code behavior present in current RTL
- Implemented with adaptation: concept implemented with different placement/details
- Verification optional/manual: not a code gap

| Plan Step | Intent | Current Status | Notes |
|---|---|---|---|
| 1 | Add BTB module | Implemented | `rtl/core/kv32_btb.sv` added |
| 2 | Add BHT module | Implemented | `rtl/core/kv32_bht.sv` added |
| 3 | Add RAS module | Implemented | `rtl/core/kv32_ras.sv` added |
| 4 | Add core params | Implemented | `BP_EN/BTB_SIZE/BHT_SIZE/RAS_EN/RAS_DEPTH` in `kv32_core` |
| 5 | Declare predictor signals | Implemented with adaptation | IF-named signals replaced by ID-centric set |
| 6 | Instantiate BTB/BHT/RAS | Implemented with adaptation | Read path uses `pc_id` in implementation |
| 7 | Combined prediction logic | Implemented with adaptation | Logic is ID-stage (`bp_pred_taken_id`) |
| 8 | IF PC update on prediction | Implemented with adaptation | Redirect path via `bp_if_flush` and fetch mux |
| 9 | Carry IF/ID prediction metadata | Implemented with adaptation | Prediction metadata carried to EX path |
| 10 | Carry ID/EX metadata | Implemented | `bp_taken_ex`/`bp_target_ex` used in EX correction |
| 11 | EX correction (`need_redirect`) | Implemented | Present and integrated into redirect path |
| 12 | Update flush + flush PC | Implemented | `if_flush/id_flush/if_flush_pc` include predictor terms |
| 13 | Update `branch_flushed` semantics | Implemented | One-shot control now tied to `need_redirect` |
| 14 | BTB/BHT update logic | Implemented | EX-stage updates present |
| 15 | RAS push/pop policy | Implemented | Push in EX, pop on accepted prediction |
| 16 | Add debug messages/group | Implemented | `DBG_GRP_BP` and BP debug prints present |
| 17 | Add SoC params | Implemented | Predictor params in `kv32_soc` |
| 18 | Pass SoC params to core | Implemented | Parameter pass-through present |
| 19 | Regressions with features enabled | Implemented | Core compare regressions executed and passing |
| 20 | Regressions with features disabled | Implemented path available | Switch via params; baseline compare path maintained |
| 21 | Trace-based behavior check | Implemented path available | Trace tooling exists and was used in flow |
| 22 | Waveform inspection | Verification optional/manual | Optional review, not architectural gap |
