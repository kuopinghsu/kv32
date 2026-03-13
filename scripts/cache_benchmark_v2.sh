#!/bin/bash
# =============================================================================
# cache_benchmark_v2.sh — Comprehensive I-cache + D-cache benchmark sweep
#
# Sweeps:
#   - Cache combos: no cache, IC only, DC only, symmetric IC+DC at 4/8/16 KB
#     in both 2-way and 4-way, plus asymmetric 2-way splits
#   - Memory types: sram (MEM_READ_LATENCY=1), ddr4-1600, ddr4-3200
#   - Benchmarks: dhry, coremark, rtos, cachebench, embench, mibench
#
# Output: build/cache_bench_v2/results.csv
# =============================================================================
set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ_DIR"

NCPU=$(nproc 2>/dev/null || echo 4)
RESULTS_DIR="$PROJ_DIR/build/cache_bench_v2"
mkdir -p "$RESULTS_DIR"
CSV="$RESULTS_DIR/results.csv"

# CSV header
echo "mem_type,ic_en,ic_size_B,ic_ways,ic_line_B,dc_en,dc_size_B,dc_ways,dc_line_B,benchmark,pass_fail,total_cycles,instructions,stall_cycles,stall_pct,cpi,ic_hits,ic_hit_pct,ic_misses,ic_fills,dc_hits,dc_hit_pct,dc_misses,dc_fills" > "$CSV"

# ──────────────────────────────────────────────────────────────────────────────
# Configurations to sweep:  (IC_EN IC_SIZE IC_WAYS IC_LINE  DC_EN DC_SIZE DC_WAYS DC_LINE)
# All sizes in bytes; 32-B cache lines throughout.
#
# 2-way configurations (original sweep):
#  cfg 0:  no cache (baseline)
#  cfg 1:  IC-4K only     (2-way)
#  cfg 2:  DC-4K only     (2-way)
#  cfg 3:  IC-4K  + DC-4K  (2-way symmetric)
#  cfg 4:  IC-8K  + DC-8K  (2-way symmetric)
#  cfg 5:  IC-16K + DC-16K (2-way symmetric)
#  cfg 6:  IC-8K  + DC-4K  (2-way IC-dominant)
#  cfg 7:  IC-4K  + DC-8K  (2-way DC-dominant)
#  cfg 8:  IC-16K + DC-8K  (2-way large IC, medium DC)
#  cfg 9:  IC-8K  + DC-16K (2-way medium IC, large DC)
#
# 4-way configurations (new — associativity comparison):
#  cfg 10: IC-4K  + DC-4K  (4-way symmetric)
#  cfg 11: IC-8K  + DC-8K  (4-way symmetric)
#  cfg 12: IC-16K + DC-16K (4-way symmetric)
# ──────────────────────────────────────────────────────────────────────────────
declare -a IC_EN_LIST=( 0     1      0      1      1      1      1      1      1      1      1      1      1    )
declare -a IC_SZ_LIST=( 4096  4096   4096   4096   8192   16384  8192   4096   16384  8192   4096   8192   16384)
declare -a IC_WY_LIST=( 2     2      2      2      2      2      2      2      2      2      4      4      4    )
declare -a IC_LN_LIST=( 32    32     32     32     32     32     32     32     32     32     32     32     32   )
declare -a DC_EN_LIST=( 0     0      1      1      1      1      1      1      1      1      1      1      1    )
declare -a DC_SZ_LIST=( 4096  4096   4096   4096   8192   16384  4096   8192   8192   16384  4096   8192   16384)
declare -a DC_WY_LIST=( 2     2      2      2      2      2      2      2      2      2      4      4      4    )
declare -a DC_LN_LIST=( 32    32     32     32     32     32     32     32     32     32     32     32     32   )

MEM_TYPES=("sram" "ddr4-1600" "ddr4-3200")
BENCHMARKS=("dhry" "coremark" "rtos" "cachebench" "embench" "mibench")

NUM_CFGS=${#IC_EN_LIST[@]}
TOTAL_CONFIGS=$(( NUM_CFGS * ${#MEM_TYPES[@]} ))
TOTAL_RUNS=$(( TOTAL_CONFIGS * ${#BENCHMARKS[@]} ))
CFG_IDX=0
RUN_IDX=0

# ──────────────────────────────────────────────────────────────────────────────
# Helper: parse metrics from a simulation log (macOS-compatible, uses perl)
# ──────────────────────────────────────────────────────────────────────────────
_pval() {
  # _pval <file> <perl-pattern>  — prints first capture group or ""
  perl -ne "print \$1,\"\n\" if /$2/ and last" "$1" 2>/dev/null | head -1
}

parse_metrics() {
  local f="$1"
  total_cycles=$(perl -ne 'print $1,"\n" if /Total cycles\s*:\s*([0-9]+)/' "$f" | head -1)
  instructions=$( perl -ne 'print $1,"\n" if /Instructions\s*:\s*([0-9]+)/' "$f" | head -1)
  stall_cycles=$( perl -ne 'print $1,"\n" if /Stall cycles\s*:\s*([0-9]+)/' "$f" | head -1)
  stall_pct=$(    perl -ne 'print $1,"\n" if /Stall cycles.*\(([0-9.]+)%\)/' "$f" | head -1)
  cpi=$(          perl -ne 'print $1,"\n" if /CPI\s*:\s*([0-9.]+)/' "$f" | head -1)

  # I-Cache — extract from "I-Cache Statistics" block
  ic_hits=$(    perl -ne '$f=1 if /I-Cache Statistics/; print $1,"\n" and last if $f && /Cache hits\s*:\s*([0-9]+)/' "$f")
  ic_hit_pct=$( perl -ne '$f=1 if /I-Cache Statistics/; print $1,"\n" and last if $f && /Cache hits.*\(([0-9.]+)%\)/' "$f")
  ic_misses=$(  perl -ne '$f=1 if /I-Cache Statistics/; print $1,"\n" and last if $f && /Cache misses\s*:\s*([0-9]+)/' "$f")
  ic_fills=$(   perl -ne '$f=1 if /I-Cache Statistics/; print $1,"\n" and last if $f && /Cache-line fills\s*:\s*([0-9]+)/' "$f")

  # D-Cache — extract from "D-Cache Statistics" block
  dc_hits=$(    perl -ne '$f=1 if /D-Cache Statistics/; print $1,"\n" and last if $f && /Cache hits\s*:\s*([0-9]+)/' "$f")
  dc_hit_pct=$( perl -ne '$f=1 if /D-Cache Statistics/; print $1,"\n" and last if $f && /Cache hits.*\(([0-9.]+)%\)/' "$f")
  dc_misses=$(  perl -ne '$f=1 if /D-Cache Statistics/; print $1,"\n" and last if $f && /Cache misses\s*:\s*([0-9]+)/' "$f")
  dc_fills=$(   perl -ne '$f=1 if /D-Cache Statistics/; print $1,"\n" and last if $f && /Cache-line fills\s*:\s*([0-9]+)/' "$f")

  # Defaults for missing fields
  total_cycles=${total_cycles:-0}; instructions=${instructions:-0}
  stall_cycles=${stall_cycles:-0}; stall_pct=${stall_pct:-0}; cpi=${cpi:-0}
  ic_hits=${ic_hits:-0};     ic_hit_pct=${ic_hit_pct:-0}
  ic_misses=${ic_misses:-0}; ic_fills=${ic_fills:-0}
  dc_hits=${dc_hits:-0};     dc_hit_pct=${dc_hit_pct:-0}
  dc_misses=${dc_misses:-0}; dc_fills=${dc_fills:-0}
}

# ──────────────────────────────────────────────────────────────────────────────
# Pre-build dhry and coremark ELFs once (no cache/mem dependency)
# ──────────────────────────────────────────────────────────────────────────────
echo "=========================================="
echo "Pre-building benchmark ELFs..."
echo "=========================================="
make build/dhry.elf       > /dev/null 2>&1 && echo "  dhry.elf OK"
make build/coremark.elf   > /dev/null 2>&1 && echo "  coremark.elf OK"
# cachebench: limit to 5 dataset sizes (1-16 KB) to keep RTL sweep time manageable
make -B build/cachebench.elf EXTRA_CFLAGS="-DCB_NUM_SIZES_LIMIT=5" \
                              > /dev/null 2>&1 && echo "  cachebench.elf OK (sizes 1-16 KB)"
make build/embench.elf    > /dev/null 2>&1 && echo "  embench.elf OK"
make build/mibench.elf    > /dev/null 2>&1 && echo "  mibench.elf OK"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# Main sweep
# ──────────────────────────────────────────────────────────────────────────────
for MEM in "${MEM_TYPES[@]}"; do
  for (( i=0; i<NUM_CFGS; i++ )); do
    IC_EN=${IC_EN_LIST[$i]}
    IC_SZ=${IC_SZ_LIST[$i]}
    IC_WY=${IC_WY_LIST[$i]}
    IC_LN=${IC_LN_LIST[$i]}
    DC_EN=${DC_EN_LIST[$i]}
    DC_SZ=${DC_SZ_LIST[$i]}
    DC_WY=${DC_WY_LIST[$i]}
    DC_LN=${DC_LN_LIST[$i]}

    CFG_IDX=$((CFG_IDX + 1))

    IC_LABEL=$([ "$IC_EN" = "1" ] && echo "$((IC_SZ/1024))K ${IC_WY}W ${IC_LN}B" || echo "off")
    DC_LABEL=$([ "$DC_EN" = "1" ] && echo "$((DC_SZ/1024))K ${DC_WY}W ${DC_LN}B" || echo "off")
    echo "=========================================="
    echo "[${CFG_IDX}/${TOTAL_CONFIGS}] MEM=${MEM}  IC=${IC_LABEL}  DC=${DC_LABEL}"
    echo "=========================================="

    # Determine RTOS_T4_TICK_FAST based on memory type and cache size.
    # Small SRAM caches (≤2KB) thrash heavily at TICK=5000; use 20000 instead.
    if [[ "$MEM" == ddr4-* ]]; then
      RTOS_TICK=30000
    elif [[ ( "$IC_EN" = "1" && "$IC_SZ" -le 2048 ) || ( "$DC_EN" = "1" && "$DC_SZ" -le 2048 ) ]]; then
      RTOS_TICK=20000
    else
      RTOS_TICK=5000
    fi

    BUILD_LOG="$RESULTS_DIR/build_${MEM}_ic${IC_EN}s${IC_SZ}dc${DC_EN}s${DC_SZ}.log"
    echo -n "  Building RTL... "
    if ! make build-rtl \
          ICACHE_EN=${IC_EN}     ICACHE_SIZE=${IC_SZ}     ICACHE_WAYS=${IC_WY}     ICACHE_LINE_SIZE=${IC_LN} \
          DCACHE_EN=${DC_EN}     DCACHE_SIZE=${DC_SZ}     DCACHE_WAYS=${DC_WY}     DCACHE_LINE_SIZE=${DC_LN} \
          MEM_TYPE=${MEM}        VERILATOR_JOBS=${NCPU} \
          > "$BUILD_LOG" 2>&1; then
      echo "BUILD FAILED — see $BUILD_LOG"
      RUN_IDX=$((RUN_IDX + ${#BENCHMARKS[@]}))
      continue
    fi
    echo "OK"

    # Build rtos ELF with correct timing for this (IC_EN, MEM_TYPE) combination
    RTOS_ELF_LOG="$RESULTS_DIR/rtos_elf_${MEM}_ic${IC_EN}.log"
    echo -n "  Building rtos.elf (TICK=${RTOS_TICK})... "
    EXTRA_RTOS_FLAGS=""
    # For ICACHE_EN=0 + DDR4, add reduced-workload flags to avoid timeout,
    # but keep T3 LOW_WORK_SLICES high enough that HIGH arrives before LOW
    # finishes the critical section (prevents spurious PI test failure).
    if [[ "$IC_EN" = "0" && "$MEM" == ddr4-* ]]; then
      EXTRA_RTOS_FLAGS="-DMRTOS_T1_RUNS=1 -DMRTOS_T2_START_DELAY=0 -DMRTOS_T2_POST_GAP=0 -DMRTOS_T3_LOW_WORK_SLICES=10 -DMRTOS_T3_MED_START_DELAY=2 -DMRTOS_T3_HIGH_START_DELAY=3 -DMRTOS_T4_ITERS=4"
    fi
    if ! make -B build/rtos.elf \
          EXTRA_CFLAGS="-DMRTOS_T4_TICK_FAST=${RTOS_TICK} ${EXTRA_RTOS_FLAGS}" \
          > "$RTOS_ELF_LOG" 2>&1; then
      echo "RTOS ELF BUILD FAILED — see $RTOS_ELF_LOG"
    else
      echo "OK"
    fi

    # Run each benchmark
    for BENCH in "${BENCHMARKS[@]}"; do
      RUN_IDX=$((RUN_IDX + 1))
      LOG="$RESULTS_DIR/${BENCH}_${MEM}_ic${IC_EN}s${IC_SZ}dc${DC_EN}s${DC_SZ}.log"
      echo -n "  [${RUN_IDX}/${TOTAL_RUNS}] ${BENCH}... "

      # rtos: 120 s wall-time limit (can thrash with tiny caches)
      # cachebench: 240 s limit (DDR4-uncached with large arrays can be slow)
      TIMEOUT_CMD=""
      [[ "$BENCH" = "rtos" ]]       && TIMEOUT_CMD="timeout 120"
      [[ "$BENCH" = "cachebench" ]] && TIMEOUT_CMD="timeout 240"

      PASS_FAIL="SKIP"
      if [[ "$BENCH" = "rtos" && ! -f "build/rtos.elf" ]]; then
        echo "SKIP (no rtos.elf)"
      elif $TIMEOUT_CMD bash -c "cd build && ./kv32soc ${BENCH}.elf" > "$LOG" 2>&1; then
        PASS_FAIL="PASS"
      else
        EXIT=$?
        [[ $EXIT -eq 124 ]] && PASS_FAIL="TIMEOUT" || PASS_FAIL="FAIL"
      fi

      parse_metrics "$LOG"

      echo "${MEM},${IC_EN},${IC_SZ},${IC_WY},${IC_LN},${DC_EN},${DC_SZ},${DC_WY},${DC_LN},${BENCH},${PASS_FAIL},${total_cycles},${instructions},${stall_cycles},${stall_pct},${cpi},${ic_hits},${ic_hit_pct},${ic_misses},${ic_fills},${dc_hits},${dc_hit_pct},${dc_misses},${dc_fills}" >> "$CSV"

      echo "${PASS_FAIL}  CPI=${cpi}  Stall=${stall_pct}%  IC-hit=${ic_hit_pct}%  DC-hit=${dc_hit_pct}%"
    done
    echo ""
  done
done

echo "=========================================="
echo "Sweep complete. Results: $CSV"
echo "=========================================="
wc -l < "$CSV" | awk '{print "Rows:", $1, "(including header)"}'
