# Plan: ARM-style Cache Diagnostic CSRs

## Overview

Add 5 custom M-mode CSRs (0x7D0–0x7D4) to KV32 so firmware can read cache
TAG/DATA SRAM and valid/dirty status — analogous to ARM Cortex-R RAMCMD/RAMINX
(CP15 c15 c2/c4). No new AXI slave. Firmware disables cache via CMO DISABLE
before dump; SRAM access is safe while FSM is in S_IDLE.

---

## CSR Map

| Addr   | Name           | R/W | Encoding |
|--------|----------------|-----|----------|
| 0x7D0  | CSR_ICAP       | RO  | [31:24]=WAYS [23:16]=NUM_SETS [15:8]=WORDS_PER_LINE [7:0]=TAG_BITS |
| 0x7D1  | CSR_DCAP       | RO  | same layout |
| 0x7D2  | CSR_CDIAG_CMD  | WO  | [31]=sel(0=I/1=D) [25:24]=way[1:0] [21:16]=set[5:0] [11:8]=word[3:0] |
| 0x7D3  | CSR_CDIAG_TAG  | RO  | [31]=dirty(D$) [30]=valid [20:0]=tag |
| 0x7D4  | CSR_CDIAG_DATA | RO  | 32-bit data word at (sel·way·set·word) |

### Timing (2-NOP firmware contract)

```asm
csrw cdiag_cmd, rs1   // cycle N:   cmd_r latched; diag_req_r=1 for one clock
nop                   // cycle N+1: SRAM CE=1 asserted (diag_req_r drives cache)
nop                   // cycle N+2: SRAM output → cache latches diag_tag_r/diag_data_r
csrr rd, cdiag_tag    // cycle N+3: reads cdiag_tag_i (combinatorial from cache reg) ✓
csrr rd, cdiag_data   // cycle N+4: reads cdiag_data_i ✓
```

---

## Phase 1 — RTL

### Step 1 — `rtl/core/kv32_pkg.sv`

Append 5 entries to `csr_addr_e` enum after `CSR_PMAADDR7`:

```systemverilog
CSR_ICAP       = 12'h7D0,
CSR_DCAP       = 12'h7D1,
CSR_CDIAG_CMD  = 12'h7D2,
CSR_CDIAG_TAG  = 12'h7D3,
CSR_CDIAG_DATA = 12'h7D4
```

### Step 2 — `rtl/core/kv32_csr.sv`

New ports:
- **inputs**: `icap_i[31:0]`, `dcap_i[31:0]`; `cdiag_tag_i[20:0]`, `cdiag_dirty_i`, `cdiag_valid_i`, `cdiag_data_i[31:0]`
- **outputs**: `cdiag_req_o`, `cdiag_sel_o`, `cdiag_way_o[1:0]`, `cdiag_set_o[5:0]`, `cdiag_word_o[3:0]`

New registers: `cmd_r[31:0]`, `diag_req_r` (1-cycle pulse)

Logic:
- Write `CDIAG_CMD` → latch `cmd_r`; pulse `diag_req_r=1` for 1 clock
- `cdiag_req_o = diag_req_r`; decoded fields driven combinatorially from `cmd_r`
- CSR reads:
  - `ICAP`       → `icap_i`
  - `DCAP`       → `dcap_i`
  - `CDIAG_CMD`  → `cmd_r`
  - `CDIAG_TAG`  → `{cdiag_dirty_i, cdiag_valid_i, 9'b0, cdiag_tag_i}`
  - `CDIAG_DATA` → `cdiag_data_i`
- ICAP/DCAP writes: silently ignored

### Step 3 — `rtl/core/kv32_core.sv` *(depends on step 2)*

Add pass-through ports matching all new kv32_csr ports; wire through the kv32_csr
instantiation. Pattern mirrors existing `pma_cfg_o`/`pma_addr_o` pass-throughs.

### Step 4 — `rtl/kv32_icache.sv` *(parallel with step 5)*

New ports:
- `cap_o[31:0]` — constant: `{WAYS[7:0], NUM_SETS[7:0], WORDS_PER_LINE[7:0], TAG_BITS[7:0]}`
- inputs: `diag_req_i`, `diag_way_i[1:0]`, `diag_set_i[INDEX_BITS-1:0]`, `diag_word_i[WORD_OFFSET_BITS-1:0]`
- outputs: `diag_valid_o` (comb from `valid_array` FF), `diag_tag_o[TAG_BITS-1:0]`, `diag_data_o[31:0]`

SRAM mux (only valid when `!cache_enable` / FSM in S_IDLE):
- `diag_req_i=1` overrides tag_sram[way].ce/addr and data_sram[way].ce/addr
- 1-cycle delayed capture: `diag_req_d` → latch `tag_sram_rdata[diag_way_d]` and
  `data_sram_rdata[diag_way_d]` into `diag_tag_r`/`diag_data_r`
- `diag_tag_o = diag_tag_r`, `diag_data_o = diag_data_r`

### Step 5 — `rtl/kv32_dcache.sv` *(parallel with step 4)*

Same as step 4, plus:
- `diag_dirty_o` — combinatorial from `dirty_array[diag_way_i][diag_set_i]`

### Step 6 — `rtl/kv32_soc.sv` *(depends on steps 3–5)*

- Wire `icache.cap_o → core.icap_i`, `dcache.cap_o → core.dcap_i`
- Route `core.cdiag_req_o` to icache or dcache based on `cdiag_sel_o`
- Add 1-cycle `sel_d` FF; mux TAG/DIRTY/VALID/DATA back to core using `sel_d`

---

## Phase 2 — Firmware *(steps 7–8 parallel)*

### Step 7 — `sw/include/kv_cap.h`

Add I-cache and D-cache packed geometry constants:

```c
/* I-cache geometry (mirrors kv32_icache.sv: 2-way, 32 sets, 16 WPL, 21-bit tag) */
#define KV_CAP_ICAP_VALUE  ((2u<<24)|(32u<<16)|(16u<<8)|21u)

/* D-cache geometry (mirrors kv32_dcache.sv: 2-way, 64 sets, 8 WPL, 21-bit tag) */
#define KV_CAP_DCAP_VALUE  ((2u<<24)|(64u<<16)|( 8u<<8)|21u)
```

### Step 8 — `sw/include/kv_cache.h`

Add after the existing CMO section:

```c
/* ── Cache Diagnostic CSRs (ARM RAMCMD/RAMINX style) ─────────────────── */

/* CSR addresses */
#define KV_CSR_ICAP         0x7D0
#define KV_CSR_DCAP         0x7D1
#define KV_CSR_CDIAG_CMD    0x7D2
#define KV_CSR_CDIAG_TAG    0x7D3
#define KV_CSR_CDIAG_DATA   0x7D4

/* CAP field extractors */
#define KV_CAP_WAYS(cap)    (((cap) >> 24) & 0xFFu)
#define KV_CAP_SETS(cap)    (((cap) >> 16) & 0xFFu)
#define KV_CAP_WPL(cap)     (((cap) >>  8) & 0xFFu)
#define KV_CAP_TAGBITS(cap) (((cap)      ) & 0xFFu)

/* CMD encoding: sel=0 → I-cache, sel=1 → D-cache */
#define KV_CDIAG_CMD_ICACHE  0u
#define KV_CDIAG_CMD_DCACHE  (1u << 31)
#define KV_CDIAG_CMD(sel, way, set, word) \
    ((uint32_t)(sel) | ((uint32_t)(way)<<24) | ((uint32_t)(set)<<16) | ((uint32_t)(word)<<8))

/* TAG result field extractors */
#define KV_CDIAG_DIRTY(t)   (((t) >> 31) & 1u)
#define KV_CDIAG_VALID(t)   (((t) >> 30) & 1u)
#define KV_CDIAG_TAG(t)     ((t) & 0x1FFFFFu)

/* Low-level helpers (2-NOP timing contract) */
static inline uint32_t kv_cdiag_tag(uint32_t cmd) {
    uint32_t r;
    __asm__ volatile (
        "csrw 0x7D2, %[c]\n nop\n nop\n csrr %[r], 0x7D3"
        : [r] "=r"(r) : [c] "r"(cmd) : "memory"
    );
    return r;
}
static inline uint32_t kv_cdiag_data(uint32_t cmd) {
    uint32_t r;
    __asm__ volatile (
        "csrw 0x7D2, %[c]\n nop\n nop\n csrr %[r], 0x7D4"
        : [r] "=r"(r) : [c] "r"(cmd) : "memory"
    );
    return r;
}

/* High-level dump API (implemented in sw/cache_diag/cache_diag.c) */
void kv_icache_dump(void);
void kv_dcache_dump(void);
void kv_cache_dump(void);
```

---

## Phase 3 — Simulator

### Step 9 — `sim/kv32sim.cpp`

Four edit locations:

1. **`known_csrs` whitelist** (~L1730): add `CSR_ICAP`, `CSR_DCAP`, `CSR_CDIAG_CMD`,
   `CSR_CDIAG_TAG`, `CSR_CDIAG_DATA`
2. **`read_csr`** (~L470):
   - `CSR_ICAP`       → return `KV_CAP_ICAP_VALUE` (compile-time constant)
   - `CSR_DCAP`       → return `KV_CAP_DCAP_VALUE`
   - `CSR_CDIAG_TAG`  → return `0` (sim has no cache model)
   - `CSR_CDIAG_DATA` → return `0`
3. **`write_csr`** (~L558): `CSR_CDIAG_CMD` → `break` (no-op)
4. **Trace name tables** (~L310, L365): add `"icap"`, `"dcap"`, `"cdiag_cmd"`,
   `"cdiag_tag"`, `"cdiag_data"` to both CSR read and write trace tables

---

## Phase 4 — Test: qsort + cache dump (`sw/cache_diag/`)

### Step 10 — `sw/cache_diag/cache_diag.c` (new file)

The file serves dual purpose: implements the dump API **and** contains `main()`.
No `makefile.mak` needed — the Makefile auto-discovers any `sw/<dir>/` with a `.c` file.

Output style: `printf`-based, same as `sw/wdt/wdt.c`.

#### Dump API implementation

```c
void kv_icache_dump(void) {
    uint32_t cap = /* csrr KV_CSR_ICAP */;
    uint32_t ways = KV_CAP_WAYS(cap), sets = KV_CAP_SETS(cap), wpl = KV_CAP_WPL(cap);
    kv_icache_disable();   // CMO_DISABLE → FSM → S_IDLE
    for (uint32_t set = 0; set < sets; set++) {
        for (uint32_t way = 0; way < ways; way++) {
            uint32_t cmd = KV_CDIAG_CMD(KV_CDIAG_CMD_ICACHE, way, set, 0);
            uint32_t tag_word = kv_cdiag_tag(cmd);
            printf("[I$] set=%2u way=%u V=%u tag=0x%06x  data:",
                   set, way, KV_CDIAG_VALID(tag_word), KV_CDIAG_TAG(tag_word));
            for (uint32_t w = 0; w < wpl; w++) {
                cmd = KV_CDIAG_CMD(KV_CDIAG_CMD_ICACHE, way, set, w);
                printf(" %08x", kv_cdiag_data(cmd));
            }
            printf("\n");
        }
    }
    kv_icache_enable();
}

// kv_dcache_dump() — same structure; uses KV_CDIAG_CMD_DCACHE;
//   also prints D=%u (dirty bit) from KV_CDIAG_DIRTY(tag_word)
// kv_cache_dump() — calls kv_icache_dump() then kv_dcache_dump()
```

#### main() — three tests

**TEST 1 — CSR geometry**
```c
uint32_t icap = /* csrr 0x7D0 */;
uint32_t dcap = /* csrr 0x7D1 */;
if (icap == KV_CAP_ICAP_VALUE && dcap == KV_CAP_DCAP_VALUE)
    printf("[TEST 1] PASS\n");
else
    printf("[TEST 1] FAIL: icap=0x%08x dcap=0x%08x\n", icap, dcap);
```

**TEST 2 — Quicksort workload** (warms I-cache and D-cache)
- 100-element `int32_t` array, LCG seed `12345` (same as `sw/mibench/mibench.c`)
- Record cycle count with `read_csr_mcycle()`; run quicksort; verify ascending order;
  compute checksum; print cycle delta and PASS/FAIL

```c
// LCG init (seed=12345, same as mibench)
uint32_t seed = 12345;
for (int i = 0; i < N; i++) {
    seed = seed * 1103515245u + 12345u;
    data[i] = (int32_t)(seed & 0x7FFFFFFFu);
}
uint32_t t0 = read_csr_mcycle();
quicksort(data, 0, N - 1);
uint32_t cycles = read_csr_mcycle() - t0;
// verify ascending + checksum, then PASS/FAIL
```

**TEST 3 — Cache dump** (diagnostic, no PASS/FAIL)
```c
printf("[TEST 3] Cache state after qsort:\n");
kv_cache_dump();
printf("[TEST 3] Done\n");
```

---

## Phase 5 — Documentation

### Step 11 — `docs/cache_architecture.md`

Append **Part III — Cache Diagnostic CSRs** section after Part II. Contents:

1. **Overview** — ARM Cortex-R RAMCMD/RAMINX analogy; CSR-only, no AXI slave; M-mode only
2. **CSR table** (0x7D0–0x7D4) — full bit-field descriptions for all 5 CSRs
3. **ICAP / DCAP encoding** — `[31:24]=WAYS [23:16]=NUM_SETS [15:8]=WPL [7:0]=TAG_BITS`;
   expected values: ICAP=`0x02201015`, DCAP=`0x02400815`
4. **CDIAG_CMD encoding** — `[31]=SEL(0=I/1=D) [25:24]=WAY [21:16]=SET [11:8]=WORD`
5. **CDIAG_TAG decoding** — `[31]=DIRTY(D$ only) [30]=VALID [20:0]=TAG`
6. **Timing: 2-NOP firmware contract** — annotated asm with per-cycle labels
7. **Safety constraint** — "SRAM diagnostic reads are only valid when the cache FSM is in
   `S_IDLE`; call `kv_icache_disable()` / `kv_dcache_disable()` (CMO_DISABLE) before
   reading `CDIAG_TAG` / `CDIAG_DATA`"
8. **SDK cross-reference** — `kv_cdiag_tag()`, `kv_cdiag_data()`, `kv_cache_dump()` in
   `sw/include/kv_cache.h`

---

## Decisions

- **No new AXI slave** — ARM-like CSR approach; no address-map or crossbar changes
- **CMO DISABLE** puts FSM in S_IDLE before dump — firmware responsibility
- **2 NOPs** in asm gap — no RTL stall logic needed
- **ICAP/DCAP** at 0x7D0/0x7D1 — runtime geometry discovery; portable dump code
- `diag_tag_o`/`diag_data_o` registered inside cache (1 FF after SRAM output);
  `sel_d` FF in `kv32_soc.sv` ensures correct mux timing
- `kv32_soc_block_diagram.svg` — no update needed (no new peripheral)

---

## Verification Checklist

- [ ] `make sim-hello` — regression must pass after all RTL changes
- [ ] `make sim-cache_diag` — ICAP/DCAP match constants; TEST 1 PASS; TEST 2 PASS; TEST 3 dump visible
- [ ] `make rtl-cache_diag` — RTL functional pass
- [ ] `make WAVE=1 rtl-cache_diag` — confirm SRAM CE/ADDR/RDATA 2-NOP timing in GTKWave
- [ ] `make compare-cache_diag` — RTL vs simulator traces match
