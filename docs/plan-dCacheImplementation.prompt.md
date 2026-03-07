# Plan: D-Cache Implementation (Task 2)

**TL;DR** — Implement `kv32_dcache.sv` as a write-back/write-through + write-allocate/no-allocate set-associative cache configurable by parameters, with PMA check guarding cacheable vs. non-cacheable paths, critical-word-first AXI WRAP fills, dirty-line eviction, CMO (CBO/FENCE.I) support, and store-buffer interaction. Instantiate it in `kv32_soc.sv` between `kv32_core`'s `dmem_req/resp` port and the AXI data master path — mirroring the I-Cache architecture exactly. Update `kv32_core.sv`, `kv32_soc.sv`, synthesis/FPGA lists, the DMA test, the datasheet, and add a `sw/dcache` test suite.

---

## Phase 1 — `kv32_dcache.sv` module

### 1. Parameters (mirror `kv32_icache`)
- `DCACHE_SIZE = 4096` — total bytes
- `DCACHE_LINE_SIZE = 32` — bytes per line (= 8 words, one AXI WRAP8 burst)
- `DCACHE_WAYS = 2` — set associativity
- `DCACHE_WRITE_BACK = 1'b1` — write policy: 1=write-back, 0=write-through
- `DCACHE_WRITE_ALLOC = 1'b1` — allocation: 1=write-allocate, 0=no-alloc on miss

Derived: `SETS = SIZE/(LINE_SIZE*WAYS)`, `SET_BITS = $clog2(SETS)`, `OFFSET_BITS = $clog2(LINE_SIZE)`, `TAG_BITS = 32 - SET_BITS - OFFSET_BITS`, `WORDS_PER_LINE = LINE_SIZE/4`.

### 2. Ports

**Core-side** (verbatim match to `kv32_core`'s `dmem_req/resp` interface):
- Inputs: `core_req_valid`, `core_req_addr[31:0]`, `core_req_we[3:0]`, `core_req_wdata[31:0]`
- Outputs: `core_req_ready`, `core_resp_valid`, `core_resp_data[31:0]`, `core_resp_error`, `core_resp_is_write`

**CMO sideband** (mirrors `kv32_icache`'s `cmo_*` ports):
- Inputs: `cmo_valid_i`, `cmo_op_i[1:0]` (0=INVAL, 1=FLUSH, 2=CLEAN), `cmo_addr_i[31:0]`
- Output: `cmo_ready_o`

**AXI4-Lite master** (full AR/R/AW/W/B channels with burst extensions: `arlen`, `arburst`, `awlen`, `awburst`, `wlast`, `rlast`)

**Misc:** `dcache_enable_i`, `dcache_idle_o` (no pending AXI; used by `core_sleep_o`)

### 3. Storage arrays (per way)
- Data: `logic [SETS-1:0][WORDS_PER_LINE-1:0][31:0] data_array [WAYS]`
- Tag: `logic [SETS-1:0][TAG_BITS-1:0] tag_array [WAYS]`
- Valid bit: `logic [SETS-1:0][WAYS-1:0] valid_array`
- Dirty bit: `logic [SETS-1:0][WAYS-1:0] dirty_array` (only meaningful when `DCACHE_WRITE_BACK=1`)
- Pseudo-LRU: `logic [SETS-1:0] plru_bit` (1 bit per set for 2-way; parameterise for higher associativity)

### 4. PMA check (mirrors I-Cache)
```systemverilog
logic pma_cacheable;
assign pma_cacheable = req_addr_r[31];   // bit[31]=1 → RAM 0x8000_0000+
assign use_dcache    = dcache_enable_i & pma_cacheable;
```

### 5. Main FSM states

| State | Action |
|-------|--------|
| `S_IDLE` | Wait for `core_req_valid`. Latch address/data/we |
| `S_LOOKUP` | Read tag/data arrays (1-cycle). Resolve hit/miss. Check dirty for eviction |
| `S_HIT_RD` | Return hit word to core (`core_resp_valid=1, is_write=0`). Update PLRU |
| `S_HIT_WR` | Write word into data array with byte-enable. Set dirty if WB mode. Return `core_resp_is_write=1`. If write-through: also initiate AXI write |
| `S_EVICT` | Victim way has dirty=1: AXI AW+W burst (INCR, awlen=WORDS-1) of full dirty line. Wait B response. Clear dirty |
| `S_FILL` | AXI AR (WRAP, arlen=WORDS-1, start at critical word). Receive beats into fill buffer. On first beat (critical word): return load data to core. On RLAST: commit to arrays, set valid, clear dirty. If miss-write + write-alloc: apply pending store after fill |
| `S_BYPASS_RD` | Non-cacheable load: single-beat AXI AR/R, return data directly |
| `S_BYPASS_WR` | Non-cacheable store: single-beat AXI AW/W/B, return `core_resp_is_write=1` |
| `S_CMO` | Handle CBO/FENCE ops: iterate sets/ways, write back dirty lines (CMO=FLUSH/CLEAN), invalidate (CMO=INVAL/FLUSH). Assert `cmo_ready_o` when done |

### 6. Write policy matrix

| Access | Cacheable hit | Cacheable miss (WB+WA) | Cacheable miss (WT+NWA) | Non-cacheable |
|--------|--------------|------------------------|--------------------------|---------------|
| Load | Return from array, update PLRU | Evict if dirty → fill → return CWF | Bypass → AXI AR/R | `S_BYPASS_RD` |
| Store | Write array directly (dirty=1 if WB; AXI write if WT) | Evict if dirty → fill → write → dirty=1 (WA); or bypass (NWA) | AXI AW/W/B (bypass) | `S_BYPASS_WR` |

### 7. Critical-word-first fill
Issue `AR` at the requesting word's address (not the aligned line base). AXI WRAP burst naturally wraps around the line boundary. Deliver the first `R` beat to the core immediately; continue receiving remaining beats in background and commit to the cache array on RLAST.

### 8. Debug messages
Add `DBG_GRP_DCACHE` at bit 18 (`0x40000`) in `rtl/core/kv32_pkg.sv`. Add `DEBUG2(\`DBG_GRP_DCACHE, ...)` messages for state transitions, hit/miss, evict/fill/bypass, CMO.

### 9. Performance counters
`perf_req_cnt`, `perf_hit_cnt`, `perf_miss_cnt`, `perf_bypass_cnt`, `perf_fill_cnt`, `perf_evict_cnt`, `perf_cmo_cnt` (32-bit, match I-Cache style).

### 10. Assertions (SVA)
`p_arvalid_stable`, `p_awvalid_stable`, `p_rlast_on_final_beat`, `p_no_multi_way_hit`, `p_dirty_only_if_valid`.

---

## Phase 2 — `kv32_core.sv` additions

### 11. New ports on `kv32_core` (minimal delta)
- `dcache_idle_i` — from D-cache, used in `core_sleep_o`
- `dcache_cmo_valid_o`, `dcache_cmo_op_o[1:0]`, `dcache_cmo_addr_o[31:0]`, `dcache_cmo_ready_i` — CMO sideband

### 12. Update `core_sleep_o`
```systemverilog
assign core_sleep_o = wfi_sleeping && (ib_outstanding == '0) && !imem_resp_valid
                      && !sb_store_pending && icache_idle_i && dcache_idle_i;
```

### 13. CMO routing — FENCE.I and CBO
Currently `is_fence_i_mem` triggers an I-cache CMO via `icache_cmo_*`. Extend to also issue a D-cache CMO (`FLUSH` = all dirty lines writeback+invalidate) simultaneously. Use a `dcache_cmo_sent_r` flip-flop (mirrors `icache_cmo_sent_r`). Stall until both `icache_cmo_ready` and `dcache_cmo_ready` de-assert.

For `is_cbo_mem` (CBO.FLUSH, CBO.CLEAN, CBO.INVAL): route to D-cache only (not I-cache — I-cache has no dirty data). Keep existing `cmo_sent_r` logic, add `dcache_cmo_*` signals.

### 14. PMA Task 1 completion
After D-cache instantiation, the D-cache internally applies `pma_cacheable = addr[31]`. The existing PMA sub-task in TODO item #1 ("Extend PMA check to D-cache") is satisfied by this.

---

## Phase 3 — `kv32_soc.sv` wiring

### 15. Inspect current data-path wiring
Examine how `kv32_core`'s `dmem_req/resp` currently reaches the AXI crossbar. This determines the exact re-wiring needed.

### 16. Instantiate `kv32_dcache`
Instantiate in `kv32_soc.sv` mirroring the `kv32_icache` instantiation block. Connect:
- Core-side ← `kv32_core`'s `dmem_req/resp` signals
- AXI master → AXI arbiter data master slot (currently M1 for core data)
- CMO ports → `kv32_core`'s new `dcache_cmo_*` ports
- `dcache_idle_o` → `kv32_core`'s `dcache_idle_i`
- `dcache_enable_i` ← `1'b1` (or CSR-controlled register in future)

### 17. Add parameters to `kv32_soc`
Add `DCACHE_SIZE`, `DCACHE_LINE_SIZE`, `DCACHE_WAYS`, `DCACHE_WRITE_BACK`, `DCACHE_WRITE_ALLOC` — propagate to `kv32_dcache` instantiation.

---

## Phase 4 — Build system updates

### 18. Synthesis file list
Add `rtl/kv32_dcache.sv` to `syn/common/rtl_filelist.f` after `kv32_icache.sv`.

### 19. FPGA compile list
Add `rtl/kv32_dcache.sv` to `fpga/build.tcl`.

### 20. Makefile
Add `DCACHE_SIZE`, `DCACHE_LINE_SIZE`, `DCACHE_WAYS`, `DCACHE_WRITE_BACK`, `DCACHE_WRITE_ALLOC` to `VERILATOR_FLAGS` as `-pvalue+...` entries and to the RTL params stamp.

---

## Phase 5 — Software test suite (`sw/dcache`)

### 21. `sw/dcache/dcache.c` test cases (mirror `sw/icache/icache.c` structure)
- **Basic hit/miss** — fill an array (force misses), re-read (verify hits via perf counters in magic device)
- **Eviction** — access enough distinct cache sets to force eviction; verify evicted data in RAM
- **Dirty eviction** — write to cache, force eviction; verify data reaches RAM via DMA read
- **Write-back coherency** — write to cache, read back via non-cacheable alias; verify consistency
- **Store-buffer interaction** — issue stores close together, verify correct ordering and no RAW hazard misfire
- **CMO flush (CBO.FLUSH)** — write to cache, issue CBO.FLUSH, verify dirty data in RAM
- **CMO invalidate (CBO.INVAL)** — write to cache, verify cache holds data, invalidate, re-read forces miss

---

## Phase 6 — DMA coherency (`sw/dma`)

### 22. Update `sw/dma/dma.c`
- Add `CBO.FLUSH` before DMA reads from previously-written cacheable memory (flush D-cache dirty lines to RAM so DMA sees fresh data)
- Add `CBO.INVAL` after DMA writes (invalidate stale cache lines so CPU reads fresh DMA-written data)
- Add comments explaining the coherency protocol

---

## Phase 7 — Documentation

### 23. `docs/pipeline_architecture.md`
Add a D-Cache section: cache geometry, write policy, fill/eviction FSM, CMO operations, FENCE.I protocol, PMA integration.

### 24. `docs/kv32_soc_datasheet.adoc`
Add D-Cache block to the memory subsystem section, parameter table, address map notes.

### 25. `docs/kv32_soc_block_diagram.svg`
Add `kv32_dcache` block between `kv32_core` and AXI data master path.

### 26. Mark TODO items and commit
Check off all sub-items in TODO.md §2 and §1's "Extend PMA to D-cache" bullet; git commit.

---

## Verification

- `make rtl-dcache` passes all seven test cases
- `make rtl-dma` still passes with coherency changes
- `make compare-dcache` — instruction trace matches `kv32sim` reference (SW sim has no cache but same memory model)
- `make DEBUG=2 DEBUG_GROUP=0x40000 rtl-dcache` — D-cache debug trace shows hit/miss/fill/evict events
- `make WAVE=1 rtl-dcache` — waveform shows AXI WRAP burst on fill, INCR burst on eviction
- `make rtl-hello` / `make rtl-full` — existing regression still passes with D-cache enabled

---

## Decisions
- Write policy is **parameterised** (`DCACHE_WRITE_BACK`, `DCACHE_WRITE_ALLOC`); PMA (bit[31]) separately controls cacheable/non-cacheable — same two-level approach matching the I-Cache design
- D-cache as **standalone `kv32_soc.sv`-level module** (not inside `kv32_core`) — mirrors I-cache placement, keeps core independent
- **Critical-word-first** using AXI `WRAP` burst (matches I-cache) — delivers first beat to core before fill completes
- `DBG_GRP_DCACHE` at **bit 18** (`0x40000`) — first free bit above `DBG_GRP_DTM` (bit 17)
- Synthesis target defaults to `DCACHE_WRITE_BACK=0` (write-through, simpler timing closure); simulation defaults to `DCACHE_WRITE_BACK=1`
