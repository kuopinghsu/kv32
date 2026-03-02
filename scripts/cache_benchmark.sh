#!/bin/bash
# =============================================================================
# cache_benchmark.sh — Run dhry and coremark with various I-cache configs
# Collects CPI, hit rate, stall %, etc. and writes a CSV results file.
#
# Speed optimizations:
#   - Verilator parallel C++ compilation via -j $(nproc)
#   - Build test ELFs once up front (they don't depend on cache params)
#   - Build RTL once per cache config, run all benchmarks per build
#   - Call simulator binary directly (skip make rtl-% wrapper overhead)
#   - Let Makefile stamp mechanism handle incremental rebuilds
# =============================================================================
set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ_DIR"

NCPU=$(nproc 2>/dev/null || echo 4)

# Store results OUTSIDE build/ because `make clean` does `rm -rf build/`
RESULTS_DIR="$PROJ_DIR/docs/cache_bench_results"
mkdir -p "$RESULTS_DIR"

CSV="$RESULTS_DIR/results.csv"

# Header
echo "benchmark,cache_size_B,cache_ways,line_size_B,sets,total_cycles,instructions,exec_cycles,stall_cycles,stall_pct,CPI,ar_requests,r_responses,fetch_lookups,cache_hits,cache_misses,hit_rate_pct,bypass_fetches,cache_line_fills" > "$CSV"

# Configurations to sweep
CACHE_SIZES=(1024 2048 4096 8192)
CACHE_WAYS_LIST=(1 2 4)
LINE_SIZES=(16 32 64)

BENCHMARKS=(dhry coremark)

# Pre-build all test ELFs once (they don't depend on cache parameters)
echo "=========================================="
echo "Pre-building test ELFs..."
echo "=========================================="
for BENCH in "${BENCHMARKS[@]}"; do
  echo "  Building ${BENCH}.elf..."
  make "build/${BENCH}.elf" > /dev/null 2>&1
done
echo "Done."
echo ""

NUM_CONFIGS=$(( ${#CACHE_SIZES[@]} * ${#CACHE_WAYS_LIST[@]} * ${#LINE_SIZES[@]} ))
TOTAL_RUNS=$(( NUM_CONFIGS * ${#BENCHMARKS[@]} ))
CFG_IDX=0
RUN_IDX=0

echo "=========================================="
echo "Cache benchmark sweep: ${NUM_CONFIGS} configs x ${#BENCHMARKS[@]} benchmarks = ${TOTAL_RUNS} runs"
echo "=========================================="
echo ""

# Parse metrics from a simulation log file
parse_metrics() {
  local logfile="$1"
  total_cycles=$(grep -oP 'Total cycles :\s+\K[0-9]+'           "$logfile" || echo "0")
  instructions=$(grep -oP 'Instructions :\s+\K[0-9]+'           "$logfile" || echo "0")
  exec_cycles=$(grep -oP 'Execution cycles :\s+\K[0-9]+'        "$logfile" || echo "0")
  stall_cycles=$(grep -oP 'Stall cycles :\s+\K[0-9]+'           "$logfile" || echo "0")
  stall_pct=$(grep -oP 'Stall cycles :\s+[0-9]+ \(\K[0-9.]+'   "$logfile" || echo "0")
  cpi=$(grep -oP 'CPI :\s+\K[0-9.]+'                            "$logfile" || echo "0")
  ar_requests=$(grep -oP 'AR Requests \(Master\) :\s+\K[0-9]+'  "$logfile" || echo "0")
  r_responses=$(grep -oP 'R Responses \(Slave\) :\s+\K[0-9]+'   "$logfile" || echo "0")
  fetch_lookups=$(grep -oP 'Fetch lookups :\s+\K[0-9]+'         "$logfile" || echo "0")
  cache_hits=$(grep -oP 'Cache hits :\s+\K[0-9]+'               "$logfile" || echo "0")
  cache_misses=$(grep -oP 'Cache misses :\s+\K[0-9]+'           "$logfile" || echo "0")
  hit_rate=$(grep -oP 'Cache hits :\s+[0-9]+ \(\K[0-9.]+'       "$logfile" || echo "0")
  bypass_fetches=$(grep -oP 'Bypass fetches :\s+\K[0-9]+'       "$logfile" || echo "0")
  cache_fills=$(grep -oP 'Cache-line fills :\s+\K[0-9]+'        "$logfile" || echo "0")
}

for CSIZE in "${CACHE_SIZES[@]}"; do
  for CWAYS in "${CACHE_WAYS_LIST[@]}"; do
    for LSIZE in "${LINE_SIZES[@]}"; do
      CFG_IDX=$((CFG_IDX + 1))

      # Compute number of sets
      SETS=$((CSIZE / CWAYS / LSIZE))
      if [ "$SETS" -lt 1 ]; then
        echo "[Config ${CFG_IDX}/${NUM_CONFIGS}] SKIP size=${CSIZE} ways=${CWAYS} line=${LSIZE} (sets<1)"
        RUN_IDX=$((RUN_IDX + ${#BENCHMARKS[@]}))
        continue
      fi

      # Build RTL once for this cache config
      echo -n "[Config ${CFG_IDX}/${NUM_CONFIGS}] Building RTL: size=${CSIZE}B ways=${CWAYS} line=${LSIZE}B (${SETS} sets)... "
      BUILD_LOG="$RESULTS_DIR/build_s${CSIZE}_w${CWAYS}_l${LSIZE}.log"

      if ! make build-rtl \
            ICACHE_SIZE=${CSIZE} \
            ICACHE_WAYS=${CWAYS} \
            ICACHE_LINE_SIZE=${LSIZE} \
            VERILATOR_JOBS=${NCPU} \
            > "$BUILD_LOG" 2>&1; then
        echo "BUILD FAILED — see $BUILD_LOG"
        RUN_IDX=$((RUN_IDX + ${#BENCHMARKS[@]}))
        continue
      fi
      echo "OK"

      # Run each benchmark with this RTL build
      for BENCH in "${BENCHMARKS[@]}"; do
        RUN_IDX=$((RUN_IDX + 1))
        echo -n "  [${RUN_IDX}/${TOTAL_RUNS}] ${BENCH}... "

        LOGFILE="$RESULTS_DIR/${BENCH}_s${CSIZE}_w${CWAYS}_l${LSIZE}.log"

        if ! (cd build && ./kv32soc ${BENCH}.elf) > "$LOGFILE" 2>&1; then
          echo "RUN FAILED — see $LOGFILE"
          continue
        fi

        parse_metrics "$LOGFILE"

        echo "${BENCH},${CSIZE},${CWAYS},${LSIZE},${SETS},${total_cycles},${instructions},${exec_cycles},${stall_cycles},${stall_pct},${cpi},${ar_requests},${r_responses},${fetch_lookups},${cache_hits},${cache_misses},${hit_rate},${bypass_fetches},${cache_fills}" >> "$CSV"

        echo "CPI=${cpi}  HitRate=${hit_rate}%  Stall=${stall_pct}%"
      done
    done
  done
done

echo ""
echo "=========================================="
echo "All runs complete. Results in: $CSV"
echo "=========================================="
cat "$CSV" | column -t -s, | head -5
echo "... ($(wc -l < "$CSV") rows total including header)"
