## Plan: KV32 Performance Roadmap Execution

Execute a staged architecture upgrade that starts with measurement visibility (software-readable counters), then improves control-flow efficiency (branch predictor quality), memory throughput (AXI read-level parallelism), and finally data-path latency tolerance (non-blocking D-cache + stronger store buffering). This ordering reduces risk by making each later optimization measurable and debuggable before introducing higher-complexity concurrency.

**Steps**
1. Phase 0: Baseline and metric contract (blocks all later phases).
- Lock baseline configs and workloads for before/after comparison: `simple`, `cachebench`, `coremark`, `rtos`, `cache_diag` under SRAM and DDR4 (`MEM_TYPE=ddr4-1600`, `MEM_TYPE=ddr4-3200`).
- Define mandatory KPIs: CPI (`cycle_count / instret_count`), branch mispredict rate, I$/D$ miss rates, stall-cycle distribution, AR-channel backpressure/queueing.
- Capture current non-synthesis counters already exposed at SoC/testbench level to seed expected ranges.

2. Phase 1: Expose software-readable performance counters (parallelizable subparts after CSR map is chosen).
- Add a dedicated KV32 custom performance CSR bank (recommended) for software consumption, mapping at least: `bp_mispred`, `bp_pred`, `ic_miss`, `dc_miss`, `stall_total`, plus optional stall breakdown (`stall_if`, `stall_mem`, `stall_sb`, `stall_cmo`).
- Ensure counters are always incrementing in RTL and simulator (not gated by `ifndef SYNTHESIS`), with a configuration parameter to disable physical implementation if needed for timing closure and area savings.
- Speperate module for counter aggregation and CSR read/clear behavior to minimize impact on core pipeline logic; use existing non-synthesis counter signals as sources where possible.
- Extend CSR decode/illegal whitelist and read paths; add optional write-1-to-clear semantics for easy A/B test loops.
- Wire existing counter sources from core/cache/SoC into CSR-facing aggregator; avoid simulation-only gating for the selected exported counters.
- Mirror support in software simulator and trace name maps so compare-mode remains stable.
- Add SDK header APIs/macros for new perf CSRs and a small software self-check app for read/clear/read behavior.

3. Phase 2: Branch predictor quality upgrade (depends on Phase 1; can be developed before Phase 1 but should be validated after).
- Keep existing prediction point in ID stage and current BTB/BHT/RAS interfaces, but improve quality with low-risk structural upgrades:
: Add optional global-history-based indexing for BHT (gshare-style XOR with PC index).
: Upgrade BTB replacement from direct-mapped behavior toward low-cost set-associative replacement (2-way + pseudo-LRU) while preserving timing boundary.
: Tighten update policy to reduce destructive aliasing (update on resolved control-flow retire points only).
- Preserve existing redirect/flush correctness and branch/RAS counters while adding one new counter for wrong-target vs wrong-direction split (recommended for diagnosis).
- Gate with parameter toggles so fallback to legacy predictor remains available for bisecting regressions.

4. Phase 3: Increase memory-level parallelism on AXI read path (can run in parallel with Phase 2 once counter plumbing is in place).
- Raise and parameterize read outstanding depth where already supported (`mem_axi_ro`, `mem_axi`, `axi_arbiter`) and ensure end-to-end ID usage remains consistent with `axi_pkg::AXI_ID_WIDTH` limits.
- Remove avoidable single-request bottlenecks in bridge readiness logic where safe (especially request acceptance coupling to channel-idle conditions), while maintaining ordering guarantees expected by core/cache clients.
- Add explicit assertions and debug counters for outstanding-count bounds, AR starvation fairness, and RID slot occupancy.
- Expose selected AXI backpressure counters through the new perf CSR bank (for example `axi_ar_stall_cycles`, `axi_r_wait_cycles`).

5. Phase 4: Non-blocking D-cache (hit-under-miss) with 1-2 MSHRs (depends on Phase 3 for maximal benefit).
- Introduce minimal MSHR table for outstanding cacheable load misses and replay path; keep stores conservative in v1.
- Allow independent hits to proceed while a miss is in flight when there is no hazard on the same line/word.
- Extend miss/fill state machine, hazard detection, and response routing; maintain precise exception behavior and existing CMO/FENCE interactions.
- Add counters: `dc_mshr_alloc`, `dc_hit_under_miss`, `dc_mshr_full_stall`.

6. Phase 5: Store-buffer optimization (can overlap late Phase 4 validation; depends on counter visibility from Phase 1).
- Increase effective store-buffer throughput via deeper queue and safe merge/coalesce policy for same-line writes.
- Improve drain scheduling to reduce read interference and avoid pathological full-buffer stalls.
- Add counters for `sb_full_stall_cycles`, `sb_merge_count`, `sb_drain_beats`.

7. Phase 6: Verification and rollout gates (blocks merge).
- For each phase, require: compile/lint clean, `sim-*`, `rtl-*`, and `compare-*` on focused tests.
- Run cross-memory regression matrix (`sram`, `ddr4-1600`, `ddr4-3200`) for representative workloads.
- Add acceptance thresholds: no functional regressions; measurable KPI improvements at roadmap level; no degradation beyond agreed tolerance on non-target workloads.

8. Phase 7: Documentation and user-facing tooling updates (after each phase, finalized at end).
- Update architecture docs with new predictor behavior, AXI outstanding model, and perf CSR programming model.
- Add SDK reference entries and usage examples for perf counter read/clear sequences.
- Update TODO tracker with phase-level completion and evidence links (commands + observed deltas).

**Relevant files**
- `/Users/kuoping/Projects/kv32/rtl/core/kv32_core.sv` — Existing branch predictor integration point, stall/cycle counters, and source for new stall breakdown signals.
- `/Users/kuoping/Projects/kv32/rtl/core/kv32_btb.sv` — BTB structure/replacement changes for predictor quality step.
- `/Users/kuoping/Projects/kv32/rtl/core/kv32_bht.sv` — BHT indexing/history update (gshare-style option).
- `/Users/kuoping/Projects/kv32/rtl/core/kv32_ras.sv` — RAS behavior/counter continuity during predictor updates.
- `/Users/kuoping/Projects/kv32/rtl/core/kv32_csr.sv` — New software-visible perf CSR read/clear bank and signal aggregation ingress.
- `/Users/kuoping/Projects/kv32/rtl/core/kv32_pkg.sv` — CSR address definitions for new perf counter CSRs.
- `/Users/kuoping/Projects/kv32/rtl/kv32_soc.sv` — Wiring existing non-synthesis counters and new always-on counter buses into core/CSR path.
- `/Users/kuoping/Projects/kv32/rtl/kv32_dcache.sv` — Non-blocking miss machinery (MSHR), hit-under-miss, and added D-cache concurrency counters.
- `/Users/kuoping/Projects/kv32/rtl/core/kv32_sb.sv` — Store-buffer depth/merge/drain policy changes and counters.
- `/Users/kuoping/Projects/kv32/rtl/mem_axi_ro.sv` — Instruction-side read bridge outstanding depth/ready policy.
- `/Users/kuoping/Projects/kv32/rtl/mem_axi.sv` — Data-side AXI bridge outstanding slots/order FIFO behavior.
- `/Users/kuoping/Projects/kv32/rtl/axi_arbiter.sv` — Read arbitration fairness and AR-channel scaling behavior.
- `/Users/kuoping/Projects/kv32/sim/kv32sim.h` — CSR defines for new perf bank.
- `/Users/kuoping/Projects/kv32/sim/kv32sim.cpp` — CSR read/write behavior and trace naming for new counters.
- `/Users/kuoping/Projects/kv32/sw/include/csr.h` — New inline CSR accessors for perf counters.
- `/Users/kuoping/Projects/kv32/sw/include/kv_cache.h` — Optional helper wrappers if counter macros are grouped with cache diagnostics.
- `/Users/kuoping/Projects/kv32/sw/cachebench/README.md` — Baseline and post-change measurement harness references.
- `/Users/kuoping/Projects/kv32/docs/pipeline_architecture.md` — Predictor and stall model documentation updates.
- `/Users/kuoping/Projects/kv32/docs/cache_architecture.md` — D-cache non-blocking behavior and metrics documentation.
- `/Users/kuoping/Projects/kv32/docs/kv32_soc_datasheet.adoc` — CSR map updates and performance counter register definitions.
- `/Users/kuoping/Projects/kv32/docs/sdk_api_reference.adoc` — Software usage model for performance CSRs.
- `/Users/kuoping/Projects/kv32/TODO.md` — Phase tracking and completion evidence.

**Verification**
1. Baseline snapshot:
- `make sim-cachebench`, `make rtl-cachebench`, `make compare-cachebench` under SRAM and DDR4 variants; archive KPI summary.
2. Counter-bank correctness:
- New software test reads counters, exercises workload, validates monotonic increments and W1C/reset behavior.
3. Predictor phase validation:
- `make sim-simple`, `make rtl-simple`, `make compare-simple` plus branch-heavy workloads (`coremark`, `rtos`) and mispredict-rate comparison.
4. AXI MLP validation:
- Run high-latency configurations (`MEM_READ_LATENCY` sweep and DDR4) and verify reduced `axi_*_stall` counters without trace mismatches.
5. D-cache non-blocking validation:
- Existing `dcache` + `cachebench` + stress tests with compare mode; assert no ordering/exception regressions.
6. Store-buffer validation:
- `fence`, `dma`, and memory-heavy tests to confirm correctness and reduced `sb_full_stall`.
7. Full regression gate:
- `make sim-all`, `make rtl-all`, `make compare-all` at default plus one high-latency memory profile.

**Decisions**
- Recommended counter exposure strategy:
- Use KV32 custom CSRs for performance counters (lower integration risk than adopting full `mhpmcounter`/`mhpmevent` architecture immediately).
- Keep counters always available in RTL and simulator (not `ifndef SYNTHESIS`), with optional synthesis parameter to disable physically if needed.
- Scope included:
- 3-step roadmap items (predictor quality, non-blocking D-cache, store-buffer optimization).
- Additional requested items (higher AXI read MLP and software-visible perf counters for mispredict/I$ miss/D$ miss/stall cycles).
- Scope excluded for this plan:
- ISA-level standardization to full privileged-spec HPM event model (can be follow-up once KV32 custom bank is stable).

**Further Considerations**
1. Counter CSR address window choice should avoid overlap with existing custom CSR ranges (`0x7C0-0x7D4` already used).
2. If timing closure risk appears in predictor upgrades, keep compile-time fallback to current direct-mapped BTB + local-history behavior.
3. For Phase 4 complexity control, start with load hit-under-miss only and defer store-miss concurrency to a later iteration.
