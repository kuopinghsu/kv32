# CacheBench — Memory Hierarchy Bandwidth Benchmark

Bare-metal adaptation of the University of Tennessee Innovative Computing
Laboratory **CacheBench** (part of LLCBENCH).

## About CacheBench

CacheBench measures effective **memory bandwidth (MB/s)** for three access
patterns at a range of dataset sizes, characterising every level of the memory
hierarchy from L1 D-cache through to DRAM:

| Operation | Description |
|-----------|-------------|
| READ | Sequential load of every element; result accumulated to prevent dead-code elimination |
| WRITE | Sequential store; data-dependent value (`r ^ i`) prevents constant-folding |
| RMW | Read-modify-write; each element incremented in place |

Dataset sizes sweep from **1 KB** (fits comfortably in L1 D-cache) to **128 KB**
(exceeds the largest supported L1 D-cache and spills to DRAM), revealing the
bandwidth cliff at each cache boundary.

**Reference**: M. Farrens & A. LaMarca, *An evaluation of memory system
performance for vector and scalar processors* — UT ICL LLCBench / CacheBench
methodology. See also: http://icl.cs.utk.edu/llcbench/

## KV32 Adaptation Notes

- **No FPU / no libc** — uses `uint32_t` arrays and integer arithmetic only
- **Timing** — `read_csr_mcycle()` from `<csr.h>`; no PAPI
- **Buffer** — `static volatile uint32_t buf[32768]` (128 KB, `.bss`), 32-byte
  cache-line aligned
- **Bandwidth formula** — `(bytes × SYS_CLK_HZ) / (cycles × 1 MiB)` using
  `uint64_t` intermediate (same as `sw/dma/dma.c`)
- **Clock** — defaults to `SYS_CLK_HZ = 100 000 000` (100 MHz); override with
  `-DSYS_CLK_HZ=<N>` via `EXTRA_CFLAGS`
- **Warm-up** — one untimed write pass before each dataset size primes the cache
  for the subsequent READ and RMW measurements

## Dataset Size Table

| Dataset | Words | Reps | Total Elements |
|---------|-------|------|----------------|
| 1 KB    | 256   | 32   | 8 192          |
| 2 KB    | 512   | 16   | 8 192          |
| 4 KB    | 1 024 | 8    | 8 192          |
| 8 KB    | 2 048 | 4    | 8 192          |
| 16 KB   | 4 096 | 2    | 8 192          |
| 32 KB   | 8 192 | 2    | 16 384         |
| 64 KB   | 16 384| 1    | 16 384         |
| 128 KB  | 32 768| 1    | 32 768         |

`words × reps` is kept roughly constant so each timed window lasts a comparable
number of cycles regardless of dataset size.

## Building and Running

```bash
# Software simulator (no cycle penalty for cache misses — flat bandwidth)
make sim-cachebench

# RTL simulation (reveals actual bandwidth drop-off at cache boundaries)
make rtl-cachebench

# RTL with D-cache disabled (pure SRAM latency baseline)
make rtl-cachebench DCACHE_EN=0

# RTL with custom clock override
make rtl-cachebench EXTRA_CFLAGS="-DSYS_CLK_HZ=50000000"

# Waveform dump for detailed inspection
make rtl-cachebench WAVE=1
```

## Expected Output

```
========================================
  KV32 CacheBench (UT/LLCBENCH-style)
========================================
  DCACHE_EN=1  (D-Cache enabled)
  SYS_CLK=100MHz  buf@0x80001060

  Size   Op     Cycles       Bandwidth
  -----  -----  -----------  ---------
    1KB  READ   ...          ... MB/s
    1KB  WRITE  ...          ... MB/s
    1KB  RMW    ...          ... MB/s
  ...
  128KB  RMW    ...          ... MB/s

CacheBench: DONE
```

With D-cache enabled, bandwidth for small datasets (≤ cache size) should be
significantly higher than for large datasets that spill to DRAM.

## Notes

- `cachebench` is excluded from trace-compare (`COMPARE_EXCLUDE` in the
  top-level `Makefile`) because cycle counts and computed MB/s values are
  inherently timing-dependent and will differ between RTL and Spike.
- For a full cache configuration sweep across memory types, add `cachebench` to
  the `BENCHMARKS` list in `scripts/cache_benchmark_v2.sh`.
