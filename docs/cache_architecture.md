# KV32 Cache Architecture

## Overview

The KV32 SoC integrates two configurable caches:

| Feature | I-Cache (`kv32_icache`) | D-Cache (`kv32_dcache`) |
|---------|------------------------|------------------------|
| RTL module | `kv32_icache` | `kv32_dcache` |
| Connected to | Instruction-fetch stage | Memory stage |
| Write path | Read-only (no stores) | Write-back or write-through |
| Dirty bits | None | One per (way, set), write-back only |
| AXI channels | AR + R only | AR + R + AW + W + B |
| CMO opcodes | INVAL, DISABLE, ENABLE, FLUSH_ALL | INVAL, FLUSH, CLEAN, FLUSH_ALL |
| FENCE.I | CMO_FLUSH_ALL invalidates all lines | CMO_FLUSH_ALL write-backs + invalidates |
| PMA attribute | X bit (I-cacheable) | C bit (D-cacheable) |

Both caches share the same foundational architecture: set-associative with configurable size, line size and ways; SRAM macros for tag and data; round-robin replacement; critical-word-first AXI4 WRAP burst fills; and an 8-region runtime-configurable PMA checker.

Both caches also expose a KV32-specific diagnostic CSR interface for geometry discovery and read-only inspection of cache tags and line data.

---

## Part I — Instruction Cache (kv32_icache)

### Diagnostic CSR Interface

The I-cache participates in the shared KV32 cache-diagnostic CSR block:

| CSR | Address | Description |
|-----|---------|-------------|
| `ICAP` | `0x7D0` | Capability word: `[31:24]=ways [23:16]=sets [15:8]=words/line [7:0]=tag_bits` |
| `CDIAG_CMD` | `0x7D2` | Issue a diagnostic read with `cache_select=0` |
| `CDIAG_TAG` | `0x7D3` | Returns `[30]=valid`, `[20:0]=tag` |
| `CDIAG_DATA` | `0x7D4` | Returns one 32-bit data word |

The command format is:

```
31            24 23            16 15             8 7            0
┌─┬────────────┬────────────────┬────────────────┬────────────────┐
│S│ WAY        │ SET            │ WORD           │   reserved     │
└─┴────────────┴────────────────┴────────────────┴────────────────┘
```

- `S=0` selects the I-cache
- `WAY`, `SET`, and `WORD` choose the inspected array entry

After software writes `CDIAG_CMD`, the cache captures the selected entry on the next cycle. Firmware should leave two instruction slots before reading `CDIAG_TAG` or `CDIAG_DATA`; the SDK helpers in `kv_cache.h` provide that timing.

### Configuration Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `CACHE_SIZE` | 4096 | Total cache capacity in bytes (must be power of 2) |
| `CACHE_LINE_SIZE` | 64 | Bytes per cache line (must be power of 2, ≥ 4) |
| `CACHE_WAYS` | 2 | Set associativity (must be power of 2, ≥ 1) |
| `FAST_INIT` | 1 | 1 = one-cycle async reset; 0 = sequential set-by-set clear |

#### Derived Geometry

| Derived Constant | Formula | Example (4 KB, 64 B, 2-way) |
|-----------------|---------|------------------------------|
| `WORDS_PER_LINE` | `CACHE_LINE_SIZE / 4` | 16 |
| `NUM_SETS` | `CACHE_SIZE / (CACHE_LINE_SIZE × CACHE_WAYS)` | 32 |
| `BYTE_OFFSET_BITS` | `$clog2(CACHE_LINE_SIZE)` | 6 |
| `WORD_OFFSET_BITS` | `$clog2(WORDS_PER_LINE)` | 4 |
| `INDEX_BITS` | `$clog2(NUM_SETS)` | 5 |
| `TAG_BITS` | `32 − INDEX_BITS − BYTE_OFFSET_BITS` | 21 |

#### Address Decomposition

```
 31          11 10        6 5      2 1 0
 ┌─────────────┬──────────┬────────┬───┐
 │  TAG[20:0]  │INDEX[4:0]│ WO[3:0]│ 0 │
 └─────────────┴──────────┴────────┴───┘
                           └─ WORD_OFFSET (word within line)
```

### Storage Organisation

**Valid bits and replacement**:
- **`valid_array[WAYS][SETS]`** — flip-flop array, one bit per (way, set), cleared on reset.
- **`victim_ptr[SETS]`** — flip-flop array; implements **round-robin** replacement. On each fill commit the pointer advances to `(fill_way + 1) % CACHE_WAYS`.

**SRAM macros** (one tag SRAM + one data SRAM per way):

| SRAM | Depth | Width | Purpose |
|------|-------|-------|---------|
| `u_tag_sram` | `NUM_SETS` | `TAG_BITS` | Tag for each (way, set) |
| `u_data_sram` | `NUM_SETS × WORDS_PER_LINE` | 32 | Instruction words |

Read address for data SRAM: `{set_index, word_offset}` from the incoming request.
Write address during fill: `{set_index, (req_word_off + fill_word_cnt) % WORDS_PER_LINE}` — wraps to match AXI WRAP semantics.

### State Machine

The I-cache controller has eight states. States are visited in the order shown for each access path:

```
  reset                                        ┌──── back-to-back hit ────┐
    ├─ FAST_INIT=0 ──► S_INIT ──┐              │                          │
    └─ FAST_INIT=1 ─────────────┴──► S_IDLE ◄──┘◄─────────────────────────┤
                                       │  │                               │
                  cmo_valid ───────────┘  └─► S_CMO ──────────────────────┘
                  imem_req_valid │
                                 ▼
                             S_LOOKUP
                            /         \
               hit+ready   /           \  miss / PMA-bypass
                          ▼             ▼
                    (→ S_IDLE)       S_MISS_AR
                                        │  AR handshake
                                     S_MISS_R
                                        │  beat 0 (critical word)
                                     S_RESP ──── fill complete + resp accepted ──► S_IDLE
                                                │ fill still active
                                           S_FILL_REST ──► S_IDLE
```

| State | Description |
|-------|-------------|
| `S_INIT` | Clears valid bits one set per cycle (FAST_INIT=0 only) |
| `S_IDLE` | Waiting for instruction fetch request or CMO |
| `S_LOOKUP` | Tag comparison (one cycle after SRAM read launched in S_IDLE) |
| `S_MISS_AR` | Driving AXI AR channel for cache-line fill or bypass fetch |
| `S_MISS_R` | Receiving AXI R burst; waiting for critical word (beat 0) |
| `S_RESP` | Holding response until core accepts (`imem_resp_ready`) |
| `S_FILL_REST` | Draining remaining fill beats after critical-word-first early restart |
| `S_CMO` | Executing a single CMO operation (one cycle) |

**Key transitions**:
- **S_IDLE → S_CMO**: `cmo_valid` asserted.
- **S_IDLE → S_LOOKUP**: `imem_req_valid` asserted.
- **S_LOOKUP → S_IDLE** (zero-stall hit): hit and `imem_resp_ready` both asserted — serves response directly from SRAM read-data, no S_RESP needed.
- **S_LOOKUP → S_RESP**: hit but core not yet ready.
- **S_LOOKUP → S_MISS_AR**: tag mismatch (miss) or PMA non-cacheable (bypass).
- **S_MISS_R → S_RESP**: beat 0 of WRAP burst arrived (critical word); or `rlast` for bypass.
- **S_RESP → S_FILL_REST**: response consumed but AXI burst still active.
- **S_FILL_REST → S_IDLE**: all fill beats received and any fill-pending response consumed.

### AXI4 Interface

#### Read Address Channel (AR)

| Signal | Cache-fill (miss) | PMA Bypass |
|--------|-------------------|------------|
| `axi_arvalid` | 1 in `S_MISS_AR` | 1 in `S_MISS_AR` |
| `axi_araddr` | `{req_addr[31:2], 2'b00}` (critical word) | `{req_addr[31:2], 2'b00}` |
| `axi_arlen` | `WORDS_PER_LINE − 1` | `8'h00` (single beat) |
| `axi_arsize` | `3'b010` (4 bytes/beat) | `3'b010` |
| `axi_arburst` | `2'b10` (WRAP) | `2'b01` (INCR) |

The WRAP burst starts at the critical word. AXI wraps at the cache-line boundary so every word in the line is fetched with the critical word arriving on beat 0. `axi_rready` is asserted in `S_MISS_R`, `S_RESP` (fill active), and `S_FILL_REST`.

### Critical-Word-First and Fill-Pending

**Critical-word-first (CWF)**: The pipeline is unblocked as soon as beat 0 of the fill burst arrives. The FSM asserts `imem_resp_valid` and enters `S_RESP`, then drains remaining beats in `S_FILL_REST`. Fetch stall penalty ≈ `memory_latency + 1` cycles instead of `memory_latency + WORDS_PER_LINE` cycles.

**Fill-pending same-line optimisation**: While `S_FILL_REST` (or `S_RESP` with an active fill) is running, the cache accepts the next sequential fetch if it targets the same cache line being filled. The required AXI beat index is tracked; when the beat arrives it is captured from the AXI bus into `fill_pend_data_r` and forwarded directly to `imem_resp_data` — no SRAM read needed.

### PMA (Physical Memory Attributes)

The cache implements an 8-region checker driven by the `pmacfg0/1` and `pmaaddr0–7` CSRs. Each region has an 8-bit configuration byte:

| Bit | Field | Meaning |
|-----|-------|---------|
| [7] | L | Lock — region is read-only until reset |
| [6:5] | — | Reserved |
| [4:3] | A | Match mode: `00`=OFF, `01`=TOR, `10`=NA4, `11`=NAPOT |
| [2] | X | **I-cacheable**: 1 = fetch may use cache |
| [1] | C | D-cacheable (not used by I-cache) |
| [0] | B | Bufferable (not used by I-cache) |

**Address-match modes**:
- **OFF** (`A=00`): Region disabled, never matches.
- **TOR** (`A=01`): Top-of-range — matches `pmaaddr[n-1]×4 ≤ addr < pmaaddr[n]×4`.
- **NA4** (`A=10`): Naturally-aligned 4 B — matches `addr[31:2] == pmaaddr`.
- **NAPOT** (`A=11`): Naturally-aligned power-of-two — `(addr>>2) & ~mask == pmaaddr & ~mask`, where `mask = pmaaddr | (pmaaddr+1)`.

**Priority**: Region 0 > Region 7. When no region matches, the **legacy fallback rule** applies: `addr[31]=1` → I-cacheable, `addr[31]=0` → not.

```
pma_cacheable = pma_hit ? pma_attr_x : req_addr_r[31]
use_cache     = cache_enable & pma_cacheable
```

When `use_cache=0`, the fetch is a **bypass**: a single-beat INCR AXI transaction, result forwarded directly without cache allocation.

### CMO and FENCE.I

| `cmo_op` | Name | Action |
|----------|------|--------|
| `2'b00` | `CMO_INVAL` | Invalidate the line matching `cmo_addr` (clear valid bit) |
| `2'b01` | `CMO_DISABLE` | Enter bypass mode — all fetches bypass cache until re-enabled |
| `2'b10` | `CMO_ENABLE` | Re-enable normal caching |
| `2'b11` | `CMO_FLUSH_ALL` | Invalidate all lines in all sets; reset all victim pointers (`FENCE.I`) |

CMO operations execute in `S_CMO` (one cycle). `CMO_FLUSH_ALL` synchronously clears all `valid_array` entries and resets all `victim_ptr` entries.

**`FENCE.I` flow**: The core issues `CMO_FLUSH_ALL` after the final store drains from the D-cache. This forces all subsequent instruction fetches to go to memory, ensuring coherence after self-modifying code.

### Initialisation

- **`FAST_INIT=1`** (default): All `valid_array` and `victim_ptr` values are cleared **asynchronously** during `rst_n` assertion. The FSM resets to `S_IDLE` and serves the first fetch on the cycle after `rst_n` deasserts.
- **`FAST_INIT=0`**: The FSM resets to `S_INIT` and clears one set per cycle for `NUM_SETS` cycles. Preferred when the memory compiler cannot efficiently synthesise a large asynchronous reset fan-out.

### Interface Summary

#### Core Instruction-Fetch Interface

| Signal | Direction | Description |
|--------|-----------|-------------|
| `imem_req_valid` | In | Fetch request valid |
| `imem_req_addr[31:0]` | In | Fetch address |
| `imem_req_ready` | Out | Cache ready to accept request |
| `imem_resp_valid` | Out | Fetch response valid |
| `imem_resp_data[31:0]` | Out | Fetched instruction word |
| `imem_resp_error` | Out | AXI RRESP error indicator |
| `imem_resp_ready` | In | Core ready to consume response |
| `imem_req_addr_fill[31:0]` | In | Loop-free fetch address for fill-pending checks |

#### CMO Sideband

| Signal | Direction | Description |
|--------|-----------|-------------|
| `cmo_valid` | In | CMO request valid |
| `cmo_op[1:0]` | In | Operation code |
| `cmo_addr[31:0]` | In | Target address (for INVAL) |
| `cmo_ready` | Out | CMO accepted |

#### PMA

| Signal | Direction | Description |
|--------|-----------|-------------|
| `pma_cfg_i[1:0][31:0]` | In | `pmacfg0` (regions 0–3), `pmacfg1` (regions 4–7) |
| `pma_addr_i[7:0][31:0]` | In | `pmaaddr0`–`pmaaddr7` (physaddr >> 2, NAPOT-encoded) |

#### Status

| Signal | Direction | Description |
|--------|-----------|-------------|
| `icache_idle` | Out | High when FSM is in `S_IDLE`; used by `kv32_pm` for WFI clock gating |

### Performance Counters

Generated for simulation only (`\`ifndef SYNTHESIS`):

| Counter | Incremented When |
|---------|-----------------|
| `perf_req_cnt` | Entering `S_LOOKUP` (one per accepted fetch) |
| `perf_hit_cnt` | `S_LOOKUP` with `use_cache=1` and tag match |
| `perf_miss_cnt` | `S_LOOKUP` with `use_cache=1` and no tag match |
| `perf_bypass_cnt` | `S_LOOKUP` with `use_cache=0` (PMA or CMO_DISABLE) |
| `perf_fill_cnt` | Successful fill commit (last beat, no error) |
| `perf_cmo_cnt` | Entering `S_CMO` (one per accepted CMO) |

**Invariant**: `perf_req_cnt == perf_hit_cnt + perf_miss_cnt + perf_bypass_cnt`

### Design Notes

**No write path**: The I-cache is read-only. No dirty bits. All evictions are silent (valid bit cleared). Cache-line fills are the only SRAM write path.

**Replacement policy**: Round-robin requires only `$clog2(CACHE_WAYS)` bits per set and is adequate for instruction-stream access patterns. 2-way round-robin is equivalent to pseudo-LRU.

**Protocol assertions** (`\`ifdef ASSERTION`): ARVALID not deasserted before ARREADY; AR signals stable while `ARVALID && !ARREADY`; RLAST on the expected beat; `imem_resp_valid` not deasserted before `imem_resp_ready`; `$onehot0(way_hit)`.

---

## Part II — Data Cache (kv32_dcache)

### Diagnostic CSR Interface

The D-cache shares the same diagnostic command path but uses `cache_select=1`:

| CSR | Address | Description |
|-----|---------|-------------|
| `DCAP` | `0x7D1` | Capability word: `[31:24]=ways [23:16]=sets [15:8]=words/line [7:0]=tag_bits` |
| `CDIAG_CMD` | `0x7D2` | Issue a diagnostic read with `cache_select=1` |
| `CDIAG_TAG` | `0x7D3` | Returns `[31]=dirty`, `[30]=valid`, `[20:0]=tag` |
| `CDIAG_DATA` | `0x7D4` | Returns one 32-bit data word |

Diagnostic reads are non-destructive: they inspect the current tag/data arrays without allocating, evicting, cleaning, or invalidating lines. This makes them suitable for cache bring-up tests such as `sw/cache_diag` and for debugging line state after software workloads.

### Configuration Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `DCACHE_SIZE` | 4096 | Total cache capacity in bytes (must be power of 2) |
| `DCACHE_LINE_SIZE` | 32 | Bytes per cache line (must be power of 2, ≥ 4) |
| `DCACHE_WAYS` | 2 | Set associativity (must be power of 2, ≥ 1) |
| `DCACHE_WRITE_BACK` | 1 | 1 = write-back; 0 = write-through |
| `DCACHE_WRITE_ALLOC` | 1 | 1 = write-allocate on store miss; 0 = no-allocate (bypass) |

#### Derived Geometry

| Derived Constant | Formula | Example (4 KB, 32 B, 2-way) |
|-----------------|---------|------------------------------|
| `WORDS_PER_LINE` | `DCACHE_LINE_SIZE / 4` | 8 |
| `NUM_SETS` | `DCACHE_SIZE / (DCACHE_LINE_SIZE × DCACHE_WAYS)` | 64 |
| `BYTE_OFFSET_BITS` | `$clog2(DCACHE_LINE_SIZE)` | 5 |
| `WORD_OFFSET_BITS` | `$clog2(WORDS_PER_LINE)` | 3 |
| `INDEX_BITS` | `$clog2(NUM_SETS)` | 6 |
| `TAG_BITS` | `32 − INDEX_BITS − BYTE_OFFSET_BITS` | 21 |

#### Address Decomposition

```
 31          11 10        5 4     2 1 0
 ┌─────────────┬──────────┬────────┬───┐
 │  TAG[20:0]  │INDEX[5:0]│ WO[2:0]│ 0 │
 └─────────────┴──────────┴────────┴───┘
                           └─ WORD_OFFSET (word within line)
```

### Storage Organisation

**Valid, dirty bits and replacement**:
- **`valid_array[WAYS][SETS]`** — flip-flop array, cleared asynchronously on `rst_n`.
- **`dirty_array[WAYS][SETS]`** — flip-flop array (write-back only), cleared asynchronously on `rst_n`. Set when a store hits a line and `DCACHE_WRITE_BACK=1`.
- **`victim_ptr[SETS]`** — flip-flop array; round-robin replacement, advanced to `(fill_way + 1) % DCACHE_WAYS` on each fill commit.

The D-cache always uses fast (asynchronous) reset: the cache is ready on the first cycle after `rst_n` deasserts.

**SRAM macros** (one tag SRAM + one data SRAM per way):

| SRAM | Depth | Width | Purpose |
|------|-------|-------|---------|
| `u_tag_sram` | `NUM_SETS` | `TAG_BITS` | Tag for each (way, set) |
| `u_data_sram` | `NUM_SETS × WORDS_PER_LINE` | 32 | Data words; byte-enable R-M-W for hit stores |

On a **hit store** the data SRAM performs a read-modify-write: the existing word (available from the SRAM read launched one cycle earlier) is byte-merged with the incoming store data and written back in the same cycle (`S_HIT_WR`).

### State Machine

The D-cache controller has 24 states, grouped by access path:

#### State Groups

**Normal access** — `S_IDLE`, `S_LOOKUP`, `S_HIT_RD`, `S_HIT_WR`

**Write-through** (`DCACHE_WRITE_BACK=0`) — `S_WT_AW`, `S_WT_W`, `S_WT_B`

**Dirty eviction** (write-back only) — `S_EVICT_AW`, `S_EVICT_W`, `S_EVICT_B`

**Fill** — `S_FILL_AR`, `S_FILL_R`, `S_FILL_RESP`, `S_FILL_REST`

**Bypass** (non-cacheable PMA) — `S_BYPASS_RD`, `S_BYPASS_WR_AW`, `S_BYPASS_WR_W`, `S_BYPASS_WR_B`

**CMO** — `S_CMO_SCAN`, `S_CMO_WB_AW`, `S_CMO_WB_W`, `S_CMO_WB_B`, `S_CMO_DONE`

#### Key Access Paths

```
  reset ──► S_IDLE ◄──────────────────────────────────────────────────────┐
              │ │                                                          │
              │ └─ cmo_valid ──► S_CMO_SCAN ──► [S_CMO_WB_AW             │
              │                   (loop)             ──► S_CMO_WB_W       │
              │                                      ──► S_CMO_WB_B]      │
              │                              ──► S_CMO_DONE ──────────────┤
              │ core_req_valid                                             │
              ▼                                                            │
           S_LOOKUP                                                        │
           /   |    \                                                      │
          /    |     \                                                     │
  hit+RD  │ hit+WR   non-cacheable ──► S_BYPASS_RD ──────────────────────►│
          │    │            └────────► S_BYPASS_WR_AW/W/B ───────────────►│
     S_HIT_RD  │    miss (clean victim) ──────────────────► S_FILL_AR     │
          │  S_HIT_WR (WB)                                       │        │
          │    │  (WT: S_WT_AW ──► S_WT_W ──► S_WT_B)    S_FILL_R        │
          │    │    miss (dirty victim) ──► S_EVICT_AW         │ beat 0   │
          │    │                               │          S_FILL_RESP      │
          │    │                           S_EVICT_W           │           │
          │    │                               │          S_FILL_REST ────►│
          │    │                           S_EVICT_B ──► S_FILL_AR        │
          └────┴──────────────────────────────────────────────────────────┘
```

**Key transitions**:
- **S_IDLE → S_CMO_SCAN**: `cmo_valid_i` asserted (any CMO op).
- **S_IDLE → S_LOOKUP**: `core_req_valid` asserted.
- **S_LOOKUP → S_IDLE** (zero-stall load hit): `use_dcache=1`, hit, load, `core_resp_ready` — response served from SRAM read-data immediately.
- **S_LOOKUP → S_HIT_WR**: `use_dcache=1`, hit, store.
- **S_LOOKUP → S_EVICT_AW**: `use_dcache=1`, miss, victim is dirty.
- **S_LOOKUP → S_FILL_AR**: `use_dcache=1`, miss, victim is clean.
- **S_LOOKUP → S_BYPASS_RD / S_BYPASS_WR_AW**: `use_dcache=0` (non-cacheable).
- **S_EVICT_B → S_FILL_AR**: dirty line written back; proceed to fill.
- **S_FILL_R → S_FILL_RESP**: beat 0 of WRAP burst (critical word) arrived.
- **S_FILL_REST → S_IDLE**: burst complete.
- **S_CMO_DONE → S_IDLE**: CMO complete.

#### State Descriptions

| State | Description |
|-------|-------------|
| `S_IDLE` | Waiting for load/store or CMO |
| `S_LOOKUP` | Tag comparison (one cycle after SRAM read) |
| `S_HIT_RD` | Hit load: hold response until core accepts |
| `S_HIT_WR` | Hit store: update SRAM (+ trigger WT AXI write if WT) |
| `S_WT_AW/W/B` | Write-through: issue AXI write for the store |
| `S_EVICT_AW/W/B` | Write-back dirty line before fill |
| `S_FILL_AR/R/RESP/REST` | WRAP burst fill; CWF unblocks core on beat 0 |
| `S_BYPASS_RD` | Non-cacheable load: single-beat INCR AXI read |
| `S_BYPASS_WR_AW/W/B` | Non-cacheable store: single-beat INCR AXI write |
| `S_CMO_SCAN` | Walk (set, way) pairs; issue write-back for each dirty line |
| `S_CMO_WB_AW/W/B` | Write back one dirty line during CMO scan |
| `S_CMO_DONE` | Pulse `cmo_ready_o`; clear remaining metadata |

### Write Policies

**Write-back** (`DCACHE_WRITE_BACK=1`):
- Hit store → update SRAM + set dirty bit; no immediate AXI write.
- Store miss → evict dirty victim (if any) → fill line → merge store → set dirty.
- Dirty lines written to memory only on eviction or CMO flush.

**Write-through** (`DCACHE_WRITE_BACK=0`):
- Hit store → update SRAM + issue AXI write (`S_WT_AW/W/B`); no dirty bit.
- No eviction ever needed.

**Write-allocate** (`DCACHE_WRITE_ALLOC=1`):
- Store miss → fill cache line, merge store data into the newly allocated line.

**No-allocate** (`DCACHE_WRITE_ALLOC=0`):
- Store miss → bypass cache (`S_BYPASS_WR_*`); no line fill.

### Dirty Eviction

On a cacheable miss where the victim line is dirty (`victim_dirty = DCACHE_WRITE_BACK && valid[victim_way][idx] && dirty[victim_way][idx]`):

1. `S_EVICT_AW`: drive AXI AW with `awaddr = {evict_tag, req_index, 0}`, `awlen = WORDS_PER_LINE−1`, `awburst = INCR`.
2. `S_EVICT_W`: send cache-line words read from SRAM one cycle ahead; `evict_wbeat_cnt` drives `axi_wlast` on the final beat.
3. `S_EVICT_B`: wait for AXI B response; clear dirty bit; transition to `S_FILL_AR`.

### AXI4 Interface

#### Read Channels (AR/R)

| Signal | Fill Mode | Bypass-Read Mode |
|--------|-----------|-----------------|
| `axi_arvalid` | 1 in `S_FILL_AR` | 1 in `S_BYPASS_RD` |
| `axi_araddr` | `{req_addr[31:2], 2'b00}` | `{req_addr[31:2], 2'b00}` |
| `axi_arlen` | `WORDS_PER_LINE − 1` | `8'h00` |
| `axi_arburst` | `2'b10` (WRAP) | `2'b01` (INCR) |

#### Write Channels (AW/W/B)

| Use | Active States | `axi_awlen` | `axi_wstrb` |
|-----|--------------|-------------|------------|
| Dirty eviction | `S_EVICT_*` | `WORDS_PER_LINE − 1` | `4'hF` |
| CMO write-back | `S_CMO_WB_*` | `WORDS_PER_LINE − 1` | `4'hF` |
| Write-through | `S_WT_*` | `8'h00` | `req_we_r` |
| Bypass store | `S_BYPASS_WR_*` | `8'h00` | `req_we_r` |

All write channels use `awburst = INCR`.

### Critical-Word-First Fill

Same strategy as the I-cache:
1. AR issued at the critical-word address using a WRAP burst.
2. Beat 0 arrival (`fill_word_cnt==0`) → response registered → `S_FILL_RESP`, core unblocked.
3. `core_resp_valid` asserted in `S_FILL_RESP`; on acceptance → `S_FILL_REST` drains remaining beats.
4. `fill_commit` (last beat, no error) → mark line valid, clear dirty.

For a **store miss + write-allocate**: CWF delivers a write-complete response (`core_resp_is_write=1`) after the line is filled and store data merged.

### PMA (Physical Memory Attributes)

The D-cache uses the same 8-region PMA checker as the I-cache (same CSRs: `pmacfg0/1`, `pmaaddr0–7`). The difference is which attribute bit gates cacheability:

| Bit | Field | Meaning (D-cache) |
|-----|-------|-------------------|
| [4:3] | A | Match mode (OFF / TOR / NA4 / NAPOT) |
| [2] | X | I-cacheable (not used by D-cache) |
| [1] | **C** | **D-cacheable: 1 = data cache may allocate** |
| [0] | B | Bufferable |

```
pma_cacheable = pma_hit ? pma_attr_c : req_addr_r[31]
use_dcache    = dcache_enable_i & pma_cacheable
```

When `use_dcache=0`: loads → `S_BYPASS_RD`; stores → `S_BYPASS_WR_*`.

### CMO and FENCE.I

| `cmo_op` | Name | Action |
|----------|------|--------|
| `2'b00` | `CMO_INVAL` | Invalidate line matching `cmo_addr`; no write-back even if dirty |
| `2'b01` | `CMO_FLUSH` | Write back dirty line at `cmo_addr`, then invalidate |
| `2'b10` | `CMO_CLEAN` | Write back dirty line at `cmo_addr`, keep valid |
| `2'b11` | `CMO_FLUSH_ALL` | Write back all dirty lines, invalidate entire cache (`FENCE.I`) |

**CMO scan algorithm** (FLUSH / CLEAN / FLUSH_ALL):
1. Enter `S_CMO_SCAN`; initialise `cmo_scan_set` and `cmo_scan_way`.
   - `CMO_FLUSH_ALL`: start at (set=0, way=0), iterate all.
   - Single-line CMO: start at the matching set, iterate all ways.
2. For each (set, way): if `valid && dirty` and op requires write-back → `S_CMO_WB_AW/W/B`, then resume scan.
3. On `cmo_scan_done` → `S_CMO_DONE`.
4. `S_CMO_DONE`: pulse `cmo_ready_o`; for `CMO_FLUSH_ALL` clear all `valid_array`, `dirty_array`, and `victim_ptr`; return to `S_IDLE`.

**`FENCE.I` flow**: The core issues `CMO_FLUSH_ALL` to the D-cache **first** (write-back all dirty data), then issues `CMO_FLUSH_ALL` to the I-cache (invalidate all fetched instructions). This ordering guarantees instruction coherence after self-modifying code.

### Interface Summary

#### Core Data-Memory Interface

| Signal | Direction | Description |
|--------|-----------|-------------|
| `core_req_valid` | In | Load/store request valid |
| `core_req_addr[31:0]` | In | Request address |
| `core_req_we[3:0]` | In | Byte-enables; `4'b0000` = load |
| `core_req_wdata[31:0]` | In | Store data |
| `core_req_ready` | Out | Cache ready to accept request |
| `core_resp_valid` | Out | Response valid |
| `core_resp_data[31:0]` | Out | Load data |
| `core_resp_error` | Out | AXI error indicator |
| `core_resp_is_write` | Out | 1 = store complete, 0 = load data |
| `core_resp_ready` | In | Core ready to consume response |

#### CMO Sideband

| Signal | Direction | Description |
|--------|-----------|-------------|
| `cmo_valid_i` | In | CMO request valid |
| `cmo_op_i[1:0]` | In | Operation code |
| `cmo_addr_i[31:0]` | In | Target address (single-line CMOs) |
| `cmo_ready_o` | Out | CMO accepted / complete |

#### PMA and Control

| Signal | Direction | Description |
|--------|-----------|-------------|
| `pma_cfg_i[1:0][31:0]` | In | `pmacfg0` (regions 0–3), `pmacfg1` (regions 4–7) |
| `pma_addr_i[7:0][31:0]` | In | `pmaaddr0`–`pmaaddr7` |
| `dcache_enable_i` | In | Global cache enable |
| `dcache_idle_o` | Out | High when FSM is in `S_IDLE` (no AXI in-flight) |

### Performance Counters

Generated for simulation only (`\`ifndef SYNTHESIS`):

| Counter | Incremented When |
|---------|-----------------|
| `perf_req_cnt` | Entering `S_LOOKUP` (one per accepted load/store) |
| `perf_hit_cnt` | `S_LOOKUP` with `use_dcache=1` and tag match |
| `perf_miss_cnt` | `S_LOOKUP` with `use_dcache=1` and no tag match |
| `perf_bypass_cnt` | `S_LOOKUP` with `use_dcache=0` (PMA non-cacheable) |
| `perf_fill_cnt` | Successful fill commit (last beat, no error) |
| `perf_evict_cnt` | `S_EVICT_B` AXI B handshake (dirty-line eviction complete) |
| `perf_cmo_cnt` | Entering `S_CMO_DONE` (one per completed CMO) |

**Invariant**: `perf_req_cnt == perf_hit_cnt + perf_miss_cnt + perf_bypass_cnt`

### Design Notes

**Byte-enable store merging**: On `S_HIT_WR` the existing SRAM word (available from the prior `S_IDLE` read) is byte-merged with the incoming store:

```systemverilog
if (req_we_r[0]) hit_wr_merged[7:0]   = req_wdata_r[7:0];
if (req_we_r[1]) hit_wr_merged[15:8]  = req_wdata_r[15:8];
if (req_we_r[2]) hit_wr_merged[23:16] = req_wdata_r[23:16];
if (req_we_r[3]) hit_wr_merged[31:24] = req_wdata_r[31:24];
```

**Eviction counter reuse**: `fill_word_cnt` is repurposed as the eviction write-beat counter during `S_EVICT_W` and `S_CMO_WB_W`. It resets at the start of each eviction and triggers `axi_wlast` when `fill_word_cnt == WORDS_PER_LINE − 1`.

**Protocol assertions** (`\`ifdef ASSERTION`): ARVALID and AWVALID not deasserted before ARREADY/AWREADY; RLAST on expected fill beat; `$onehot0(way_hit)`; dirty bits only set on valid lines.
