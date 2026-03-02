# KV32 Instruction Cache Benchmark Report

**Generated**: 2026-03-02  
**Benchmarks**: Dhrystone (`dhry`), CoreMark (`coremark`)  
**Sweep**: 36 cache configurations × 2 benchmarks = 72 simulation runs  
**Raw data**: `build/cache_bench_results/results.csv`

---

## 1. Sweep Parameters

| Parameter | Values swept |
|-----------|-------------|
| Cache size | 1 KB, 2 KB, 4 KB, 8 KB |
| Associativity (ways) | 1-way, 2-way, 4-way |
| Cache-line size | 16 B, 32 B, 64 B |

**Sets** = cache\_size / (ways × line\_size). Configurations yielding < 1 set were skipped (none in this sweep).

The default RTL configuration is **4 KB, 2-way, 32 B lines** (128 sets).

---

## 2. Summary — Best and Worst Configurations

### Dhrystone

| Rank | Config | CPI | Hit rate | Stall % |
|------|--------|-----|----------|---------|
| Best (tied) | 4 KB+ any ways, any line | 2.02 | ≥99.73% | ~50.5% |
| Worst | 1 KB 1-way 64 B | **2.33** | 98.47% | **57.13%** |
| Default (4 KB 2W 32 B) | — | **2.02** | 99.86% | 50.52% |

Dhrystone saturates at 4 KB: every configuration ≥ 4 KB (and several ≥ 2 KB 4-way) achieves CPI = 2.02. The working set fits entirely in cache.

### CoreMark

| Rank | Config | CPI | Hit rate | Stall % |
|------|--------|-----|----------|---------|
| Best | 8 KB 4-way 16 B | **1.97** | 99.39% | **49.30%** |
| Best (tied) | 8 KB 2-way 16 B | **1.97** | 99.36% | 49.34% |
| Best (tied) | 8 KB 4-way 32 B | **1.97** | 99.64% | 49.33% |
| Worst | 1 KB 1-way 64 B | **2.21** | 98.64% | **54.79%** |
| Default (4 KB 2W 32 B) | — | **2.00** | 99.38% | 49.99% |

CoreMark's working set is larger; gains continue as cache grows to 8 KB.

---

## 3. Full Results Table

### 3.1 Dhrystone

| Size | Ways | Line | Sets | CPI  | Hit %  | Stall % | Misses | Fills |
|------|------|------|------|------|--------|---------|--------|-------|
| 1 KB | 1 | 16 B | 64 | 2.20 | 96.45 | 54.54 | 4401 | 4400 |
| 1 KB | 1 | 32 B | 32 | 2.20 | 98.13 | 54.62 | 2360 | 2360 |
| 1 KB | 1 | 64 B | 16 | 2.33 | 98.47 | 57.13 | 1931 | 1931 |
| 1 KB | 2 | 16 B | 32 | 2.10 | 98.22 | 52.40 | 2239 | 2238 |
| 1 KB | 2 | 32 B | 16 | 2.12 | 98.85 | 52.91 | 1453 | 1453 |
| 1 KB | 2 | 64 B | 8  | 2.18 | 99.17 | 54.16 | 1052 | 1052 |
| 1 KB | 4 | 16 B | 16 | 2.05 | 99.26 | 51.28 | 937  | 936  |
| 1 KB | 4 | 32 B | 8  | 2.07 | 99.40 | 51.73 | 757  | 757  |
| 1 KB | 4 | 64 B | 4  | 2.12 | 99.49 | 52.90 | 649  | 649  |
| 2 KB | 1 | 16 B | 128 | 2.14 | 97.64 | 53.19 | 2936 | 2935 |
| 2 KB | 1 | 32 B | 64 | 2.14 | 98.74 | 53.17 | 1588 | 1588 |
| 2 KB | 1 | 64 B | 32 | 2.23 | 98.96 | 55.08 | 1311 | 1311 |
| 2 KB | 2 | 16 B | 64 | 2.04 | 99.46 | 51.04 | 679  | 678  |
| 2 KB | 2 | 32 B | 32 | 2.05 | 99.60 | 51.33 | 509  | 509  |
| 2 KB | 2 | 64 B | 16 | 2.07 | 99.67 | 51.77 | 415  | 415  |
| 2 KB | 4 | 16 B | 32 | 2.02 | 99.71 | 50.60 | 371  | 370  |
| 2 KB | 4 | 32 B | 16 | 2.02 | 99.84 | 50.58 | 202  | 202  |
| 2 KB | 4 | 64 B | 8  | 2.02 | 99.91 | 50.60 | 110  | 110  |
| 4 KB | 1 | 16 B | 256 | 2.02 | 99.74 | 50.55 | 335  | 334  |
| 4 KB | 1 | 32 B | 128 | 2.02 | 99.86 | 50.52 | 180  | 180  |
| 4 KB | 1 | 64 B | 64 | 2.02 | 99.92 | 50.56 | 103  | 103  |
| **4 KB** | **2** | **32 B** | **64** | **2.02** | **99.86** | **50.52** | **180** | **180** |
| 4 KB | 2 | 16 B | 128 | 2.02 | 99.74 | 50.55 | 335  | 334  |
| 4 KB | 2 | 64 B | 32 | 2.02 | 99.92 | 50.54 | 97   | 97   |
| 4 KB | 4 | 16 B | 64 | 2.02 | 99.73 | 50.56 | 346  | 345  |
| 4 KB | 4 | 32 B | 32 | 2.02 | 99.85 | 50.54 | 186  | 186  |
| 4 KB | 4 | 64 B | 16 | 2.02 | 99.92 | 50.55 | 100  | 100  |
| 8 KB | 1 | 16 B | 512 | 2.02 | 99.75 | 50.53 | 318  | 317  |
| 8 KB | 1 | 32 B | 256 | 2.02 | 99.87 | 50.49 | 166  | 166  |
| 8 KB | 1 | 64 B | 128 | 2.02 | 99.93 | 50.49 | 85   | 85   |
| 8 KB | 2 | 16 B | 256 | 2.02 | 99.75 | 50.53 | 318  | 317  |
| 8 KB | 2 | 32 B | 128 | 2.02 | 99.87 | 50.49 | 166  | 166  |
| 8 KB | 2 | 64 B | 64 | 2.02 | 99.93 | 50.49 | 85   | 85   |
| 8 KB | 4 | 16 B | 128 | 2.02 | 99.75 | 50.53 | 318  | 317  |
| 8 KB | 4 | 32 B | 64 | 2.02 | 99.87 | 50.49 | 166  | 166  |
| 8 KB | 4 | 64 B | 32 | 2.02 | 99.93 | 50.49 | 85   | 85   |

### 3.2 CoreMark

| Size | Ways | Line | Sets | CPI  | Hit %  | Stall % | Misses | Fills |
|------|------|------|------|------|--------|---------|--------|-------|
| 1 KB | 1 | 16 B | 64 | 2.13 | 96.86 | 52.94 | 39067 | 39066 |
| 1 KB | 1 | 32 B | 32 | 2.14 | 98.05 | 53.24 | 24441 | 24441 |
| 1 KB | 1 | 64 B | 16 | 2.21 | 98.64 | 54.79 | 17194 | 17194 |
| 1 KB | 2 | 16 B | 32 | 2.08 | 97.58 | 51.87 | 30241 | 30240 |
| 1 KB | 2 | 32 B | 16 | 2.09 | 98.51 | 52.15 | 18759 | 18759 |
| 1 KB | 2 | 64 B | 8  | 2.15 | 98.94 | 53.49 | 13471 | 13471 |
| 1 KB | 4 | 16 B | 16 | 2.07 | 97.65 | 51.74 | 29345 | 29344 |
| 1 KB | 4 | 32 B | 8  | 2.08 | 98.63 | 51.87 | 17339 | 17339 |
| 1 KB | 4 | 64 B | 4  | 2.11 | 99.10 | 52.68 | 11337 | 11337 |
| 2 KB | 1 | 16 B | 128 | 2.04 | 98.19 | 51.06 | 22738 | 22737 |
| 2 KB | 1 | 32 B | 64 | 2.05 | 98.88 | 51.27 | 14212 | 14212 |
| 2 KB | 1 | 64 B | 32 | 2.10 | 99.21 | 52.27 | 10016 | 10016 |
| 2 KB | 2 | 16 B | 64 | 2.02 | 98.52 | 50.54 | 18640 | 18639 |
| 2 KB | 2 | 32 B | 32 | 2.02 | 99.13 | 50.59 | 11034 | 11034 |
| 2 KB | 2 | 64 B | 16 | 2.05 | 99.41 | 51.28 | 7482  | 7482  |
| 2 KB | 4 | 16 B | 32 | 2.02 | 98.54 | 50.50 | 18441 | 18440 |
| 2 KB | 4 | 32 B | 16 | 2.02 | 99.15 | 50.54 | 10764 | 10764 |
| 2 KB | 4 | 64 B | 8  | 2.04 | 99.47 | 51.01 | 6722  | 6722  |
| 4 KB | 1 | 16 B | 256 | 2.01 | 98.77 | 50.22 | 15598 | 15597 |
| 4 KB | 1 | 32 B | 128 | 2.01 | 99.26 | 50.30 | 9413  | 9413  |
| 4 KB | 1 | 64 B | 64 | 2.04 | 99.50 | 50.91 | 6411  | 6411  |
| 4 KB | 2 | 16 B | 128 | 2.00 | 98.95 | 49.95 | 13339 | 13338 |
| **4 KB** | **2** | **32 B** | **64** | **2.00** | **99.38** | **49.99** | **7886** | **7886** |
| 4 KB | 2 | 64 B | 32 | 2.02 | 99.60 | 50.39 | 5062  | 5062  |
| 4 KB | 4 | 16 B | 64 | 2.00 | 98.98 | 49.89 | 12899 | 12898 |
| 4 KB | 4 | 32 B | 32 | 2.00 | 99.39 | 49.94 | 7708  | 7708  |
| 4 KB | 4 | 64 B | 16 | 2.01 | 99.61 | 50.35 | 4976  | 4976  |
| 8 KB | 1 | 16 B | 512 | 1.98 | 99.29 | 49.46 | 9076  | 9075  |
| 8 KB | 1 | 32 B | 256 | 1.98 | 99.57 | 49.51 | 5516  | 5516  |
| 8 KB | 1 | 64 B | 128 | 2.00 | 99.71 | 49.88 | 3693  | 3693  |
| 8 KB | 2 | 16 B | 256 | 1.97 | 99.36 | 49.34 | 8133  | 8132  |
| 8 KB | 2 | 32 B | 128 | 1.98 | 99.62 | 49.38 | 4895  | 4895  |
| 8 KB | 2 | 64 B | 64 | 1.99 | 99.75 | 49.67 | 3186  | 3186  |
| **8 KB** | **4** | **16 B** | **128** | **1.97** | **99.39** | **49.30** | **7702** | **7701** |
| 8 KB | 4 | 32 B | 64 | 1.97 | 99.64 | 49.33 | 4572  | 4572  |
| 8 KB | 4 | 64 B | 32 | 1.98 | 99.77 | 49.56 | 2900  | 2900  |

---

## 4. Analysis

### 4.1 Effect of Cache Size

Cache size is the dominant performance lever for both workloads.

| Cache Size | dhry CPI (best) | coremark CPI (best) |
|-----------|-----------------|---------------------|
| 1 KB | 2.05 | 2.07 |
| 2 KB | 2.02 | 2.02 |
| 4 KB | 2.02 | 2.00 |
| 8 KB | 2.02 | 1.97 |

- **Dhrystone saturates at 2 KB 4-way (or 4 KB direct-mapped)** — its instruction working set fits entirely in ~4 KB, so larger caches show no further CPI improvement.
- **CoreMark continues to improve through 8 KB** — its working set is larger; going 4 KB→8 KB drops CPI from 2.00 to 1.97 with best associativity.

### 4.2 Effect of Associativity (Ways)

With small caches (1 KB), more ways meaningfully reduce conflict misses:

| Config | dhry CPI | coremark CPI |
|--------|----------|--------------|
| 1 KB 1-way 32 B | 2.20 | 2.14 |
| 1 KB 2-way 32 B | 2.12 | 2.09 |
| 1 KB 4-way 32 B | 2.07 | 2.08 |

At ≥ 4 KB, the gains from additional ways are negligible — direct-mapped 4 KB performs identically to 4-way 4 KB for Dhrystone. The small remaining gap in CoreMark (2.01 vs 2.00) suggests modest conflict miss reduction.

### 4.3 Effect of Cache-Line Size

Larger cache lines increase the hit rate (more spatial locality per fill) but also increase the stall penalty when a miss occurs, because each fill requires more AXI burst beats from the RAM.

| Line | dhry CPI (1 KB 1W) | coremark CPI (1 KB 1W) |
|------|--------------------|------------------------|
| 16 B | 2.20 | 2.13 |
| 32 B | 2.20 | 2.14 |
| 64 B | **2.33** | **2.21** |

At small cache sizes, 64 B lines increase stall % by 2–3 pp despite higher hit rates — the fill penalty outweighs the miss-rate benefit. At ≥ 4 KB the hit rate is already so high (> 99.7%) that line-size choice is irrelevant for Dhrystone; CoreMark similarly shows <0.04 CPI difference across line sizes at 4 KB+.

**32 B lines offer the best overall trade-off**: higher hit rate than 16 B with lower fill penalty than 64 B.

### 4.4 Stall Cycle Breakdown

Stall cycles (~50% of all cycles at near-saturation) represent the pipeline waiting for ICache fills. This is a structural cost of the current in-order pipeline: every fetch miss stalls decode/execute. At the best cache configs, roughly half of all cycles are stall-free execution, and half are cache-induced stalls. This strongly motivates considering out-of-order execution or store-and-forward fetch buffering in future work.

---

## 5. Recommendations

### Recommended Configuration: **4 KB, 2-way, 32 B lines** *(current default)*

The default configuration delivers near-optimal performance for both benchmarks:
- Dhrystone: CPI = 2.02, hit rate = 99.86%
- CoreMark: CPI = 2.00, hit rate = 99.38%

Going to 8 KB would yield only a 1.5% CPI improvement on CoreMark at roughly double the area/power cost; it is **not recommended** unless coremark-like workloads dominate.

### Area-budget guidance

| Budget | Recommended config | dhry CPI | coremark CPI | Notes |
|--------|-------------------|----------|--------------|-------|
| Tight (1 KB) | 1 KB 4-way 32 B | 2.07 | 2.08 | 3–8% slower; 4-way a must at this size |
| Balanced (2 KB) | 2 KB 2-way 32 B | 2.05 | 2.02 | Good. Halves area vs default |
| **Default (4 KB)** | **4 KB 2-way 32 B** | **2.02** | **2.00** | **Optimal for most workloads** |
| Performance (8 KB) | 8 KB 2-way 32 B | 2.02 | 1.98 | Marginal gain; recommended for DSP/compute |

### What to avoid
- **64 B lines with small caches** (≤ 2 KB): stall penalty exceeds hit-rate gain
- **8 KB+ with 1 KB workloads**: zero benefit, wasted silicon

---

## 6. Baseline — No Cache

For reference, the pipeline without an instruction cache would require fetching every instruction directly from AXI RAM with round-trip latency. A back-of-envelope estimate based on observed miss penalties suggests CPI would exceed 4.0 for typical code, roughly 2× worse than the ICache-equipped baseline at 4 KB.

---

## 7. Test Methodology

- Each run simulates the complete benchmark to exit via the `tohost` write mechanism
- `kv32soc` is re-built by Verilator for each cache configuration via `-pvalue+` overrides
- ELFs are pre-built once and reused across all 36 RTL builds
- Metrics are extracted directly from the simulation statistics banner printed to stdout
- All results were collected on a single host (no thermal throttling protection; minor cycle-count variation across runs is expected)
