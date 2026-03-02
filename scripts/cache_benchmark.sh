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

RESULTS_DIR="$PROJ_DIR/build/cache_bench_results"
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
  total_cycles=$(perl -ne 'print $1 if /Total cycles\s*:\s*([0-9]+)/'          "$logfile" || echo "0")
  instructions=$(perl -ne 'print $1 if /Instructions\s*:\s*([0-9]+)/'          "$logfile" || echo "0")
  exec_cycles=$(perl -ne 'print $1 if /Execution cycles\s*:\s*([0-9]+)/'       "$logfile" || echo "0")
  stall_cycles=$(perl -ne 'print $1 if /Stall cycles\s*:\s*([0-9]+)/'          "$logfile" || echo "0")
  stall_pct=$(perl -ne 'print $1 if /Stall cycles\s*:\s*[0-9]+\s*\(([0-9.]+)/' "$logfile" || echo "0")
  cpi=$(perl -ne 'print $1 if /CPI\s*:\s*([0-9.]+)/'                           "$logfile" || echo "0")
  ar_requests=$(perl -ne 'print $1 if /AR Requests \(Master\)\s*:\s*([0-9]+)/' "$logfile" || echo "0")
  r_responses=$(perl -ne 'print $1 if /R Responses \(Slave\)\s*:\s*([0-9]+)/'  "$logfile" || echo "0")
  fetch_lookups=$(perl -ne 'print $1 if /Fetch lookups\s*:\s*([0-9]+)/'        "$logfile" || echo "0")
  cache_hits=$(perl -ne 'print $1 if /Cache hits\s*:\s*([0-9]+)/'              "$logfile" || echo "0")
  cache_misses=$(perl -ne 'print $1 if /Cache misses\s*:\s*([0-9]+)/'          "$logfile" || echo "0")
  hit_rate=$(perl -ne 'print $1 if /Cache hits\s*:\s*[0-9]+\s*\(([0-9.]+)/'   "$logfile" || echo "0")
  bypass_fetches=$(perl -ne 'print $1 if /Bypass fetches\s*:\s*([0-9]+)/'      "$logfile" || echo "0")
  cache_fills=$(perl -ne 'print $1 if /Cache-line fills\s*:\s*([0-9]+)/'       "$logfile" || echo "0")

  # Default to "0" if perl returned empty string
  total_cycles=${total_cycles:-0}
  instructions=${instructions:-0}
  exec_cycles=${exec_cycles:-0}
  stall_cycles=${stall_cycles:-0}
  stall_pct=${stall_pct:-0}
  cpi=${cpi:-0}
  ar_requests=${ar_requests:-0}
  r_responses=${r_responses:-0}
  fetch_lookups=${fetch_lookups:-0}
  cache_hits=${cache_hits:-0}
  cache_misses=${cache_misses:-0}
  hit_rate=${hit_rate:-0}
  bypass_fetches=${bypass_fetches:-0}
  cache_fills=${cache_fills:-0}
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
