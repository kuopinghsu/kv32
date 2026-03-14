#!/bin/bash
# =============================================================================
# cache_benchmark_v2.sh — Cache and predictor benchmark sweeps
#
# MODE=cache      : original cache hierarchy sweep (default)
# MODE=predictor  : BTB/BHT/RAS sizing sweep at fixed IC-8K + DC-8K (2-way)
# MODE=all        : run both
#
# Output:
#   build/cache_bench_v2/results.csv            (cache mode)
#   build/cache_bench_v2/predictor_results.csv  (predictor mode)
# =============================================================================
set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ_DIR"

if command -v nproc >/dev/null 2>&1; then
  NCPU=$(nproc)
else
  NCPU=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
fi

RESULTS_DIR="$PROJ_DIR/build/cache_bench_v2"
mkdir -p "$RESULTS_DIR"

MODE=${MODE:-cache}
QUICK=${QUICK:-0}

# Split-friendly env override: MEM_TYPES="sram ddr4-1600 ddr4-3200"
MEM_TYPES=(${MEM_TYPES:-"sram ddr4-1600 ddr4-3200"})

# Helper: run command with optional timeout in a macOS-friendly way.
run_with_timeout() {
  local timeout_s="$1"
  shift

  if [[ "$timeout_s" -le 0 ]]; then
    "$@"
    return $?
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_s" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout_s" "$@"
    return $?
  fi

  "$@"
  return $?
}

parse_metrics() {
  local f="$1"
  total_cycles=$(perl -ne 'print $1,"\n" if /Total cycles\s*:\s*([0-9]+)/' "$f" | head -1)
  instructions=$( perl -ne 'print $1,"\n" if /Instructions\s*:\s*([0-9]+)/' "$f" | head -1)
  stall_cycles=$( perl -ne 'print $1,"\n" if /Stall cycles\s*:\s*([0-9]+)/' "$f" | head -1)
  stall_pct=$(    perl -ne 'print $1,"\n" if /Stall cycles.*\(([0-9.]+)%\)/' "$f" | head -1)
  cpi=$(          perl -ne 'print $1,"\n" if /CPI\s*:\s*([0-9.]+)/' "$f" | head -1)

  ic_hits=$(    perl -ne '$f=1 if /I-Cache Statistics/; print $1,"\n" and last if $f && /Cache hits\s*:\s*([0-9]+)/' "$f")
  ic_hit_pct=$( perl -ne '$f=1 if /I-Cache Statistics/; print $1,"\n" and last if $f && /Cache hits.*\(([0-9.]+)%\)/' "$f")
  ic_misses=$(  perl -ne '$f=1 if /I-Cache Statistics/; print $1,"\n" and last if $f && /Cache misses\s*:\s*([0-9]+)/' "$f")
  ic_fills=$(   perl -ne '$f=1 if /I-Cache Statistics/; print $1,"\n" and last if $f && /Cache-line fills\s*:\s*([0-9]+)/' "$f")

  dc_hits=$(    perl -ne '$f=1 if /D-Cache Statistics/; print $1,"\n" and last if $f && /Cache hits\s*:\s*([0-9]+)/' "$f")
  dc_hit_pct=$( perl -ne '$f=1 if /D-Cache Statistics/; print $1,"\n" and last if $f && /Cache hits.*\(([0-9.]+)%\)/' "$f")
  dc_misses=$(  perl -ne '$f=1 if /D-Cache Statistics/; print $1,"\n" and last if $f && /Cache misses\s*:\s*([0-9]+)/' "$f")
  dc_fills=$(   perl -ne '$f=1 if /D-Cache Statistics/; print $1,"\n" and last if $f && /Cache-line fills\s*:\s*([0-9]+)/' "$f")

  # Branch predictor stats (present only when BP_EN=1; zero otherwise)
  bp_branches=$(  perl -ne '$f=1 if /Branch Predictor Statistics/; print $1,"\n" and last if $f && /Conditional branches\s*:\s*([0-9]+)/' "$f")
  bp_jumps=$(     perl -ne '$f=1 if /Branch Predictor Statistics/; print $1,"\n" and last if $f && /Unconditional jumps\s*:\s*([0-9]+)/' "$f")
  bp_preds=$(     perl -ne '$f=1 if /Branch Predictor Statistics/; print $1,"\n" and last if $f && /Taken predictions\s*:\s*([0-9]+)/' "$f")
  bp_mispreds=$(  perl -ne '$f=1 if /Branch Predictor Statistics/; print $1,"\n" and last if $f && /Mispredictions\s*:\s*([0-9]+)/' "$f")
  bp_accuracy=$(  perl -ne '$f=1 if /Branch Predictor Statistics/; print $1,"\n" and last if $f && /Prediction accuracy\s*:\s*([0-9.]+)/' "$f")
  bp_ras_pushes=$(perl -ne '$f=1 if /Branch Predictor Statistics/; print $1,"\n" and last if $f && /RAS pushes.*:\s*([0-9]+)/' "$f")
  bp_ras_pops=$(  perl -ne '$f=1 if /Branch Predictor Statistics/; print $1,"\n" and last if $f && /RAS pops.*:\s*([0-9]+)/' "$f")

  total_cycles=${total_cycles:-0}; instructions=${instructions:-0}
  stall_cycles=${stall_cycles:-0}; stall_pct=${stall_pct:-0}; cpi=${cpi:-0}
  ic_hits=${ic_hits:-0};     ic_hit_pct=${ic_hit_pct:-0}
  ic_misses=${ic_misses:-0}; ic_fills=${ic_fills:-0}
  dc_hits=${dc_hits:-0};     dc_hit_pct=${dc_hit_pct:-0}
  dc_misses=${dc_misses:-0}; dc_fills=${dc_fills:-0}
  bp_branches=${bp_branches:-0};   bp_jumps=${bp_jumps:-0}
  bp_preds=${bp_preds:-0};         bp_mispreds=${bp_mispreds:-0}
  bp_accuracy=${bp_accuracy:-0};   bp_ras_pushes=${bp_ras_pushes:-0}
  bp_ras_pops=${bp_ras_pops:-0}
}

prebuild_cache_benchmarks() {
  echo "=========================================="
  echo "Pre-building cache benchmark ELFs..."
  echo "=========================================="
  make build/dhry.elf       > /dev/null 2>&1 && echo "  dhry.elf OK"
  make build/coremark.elf   > /dev/null 2>&1 && echo "  coremark.elf OK"
  make -B build/cachebench.elf EXTRA_CFLAGS="-DCB_NUM_SIZES_LIMIT=5" \
                                > /dev/null 2>&1 && echo "  cachebench.elf OK (sizes 1-16 KB)"
  make build/embench.elf    > /dev/null 2>&1 && echo "  embench.elf OK"
  make build/mibench.elf    > /dev/null 2>&1 && echo "  mibench.elf OK"
  echo ""
}

prebuild_predictor_benchmarks() {
  echo "=========================================="
  echo "Pre-building predictor benchmark ELFs..."
  echo "=========================================="
  make -B build/btbbench.elf > /dev/null 2>&1 && echo "  btbbench.elf OK"
  make -B build/bhtbench.elf > /dev/null 2>&1 && echo "  bhtbench.elf OK"
  make -B build/rasbench.elf > /dev/null 2>&1 && echo "  rasbench.elf OK"
  echo ""
}

run_cache_mode() {
  local csv="$RESULTS_DIR/results.csv"
  echo "mem_type,ic_en,ic_size_B,ic_ways,ic_line_B,dc_en,dc_size_B,dc_ways,dc_line_B,benchmark,pass_fail,total_cycles,instructions,stall_cycles,stall_pct,cpi,ic_hits,ic_hit_pct,ic_misses,ic_fills,dc_hits,dc_hit_pct,dc_misses,dc_fills" > "$csv"

  declare -a IC_EN_LIST=( 0     1      0      1      1      1      1      1      1      1      1      1      1    )
  declare -a IC_SZ_LIST=( 4096  4096   4096   4096   8192   16384  8192   4096   16384  8192   4096   8192   16384)
  declare -a IC_WY_LIST=( 2     2      2      2      2      2      2      2      2      2      4      4      4    )
  declare -a IC_LN_LIST=( 32    32     32     32     32     32     32     32     32     32     32     32     32   )
  declare -a DC_EN_LIST=( 0     0      1      1      1      1      1      1      1      1      1      1      1    )
  declare -a DC_SZ_LIST=( 4096  4096   4096   4096   8192   16384  4096   8192   8192   16384  4096   8192   16384)
  declare -a DC_WY_LIST=( 2     2      2      2      2      2      2      2      2      2      4      4      4    )
  declare -a DC_LN_LIST=( 32    32     32     32     32     32     32     32     32     32     32     32     32   )

  local benchmarks=("dhry" "coremark" "rtos" "cachebench" "embench" "mibench")

  local num_cfgs=${#IC_EN_LIST[@]}
  local total_configs=$(( num_cfgs * ${#MEM_TYPES[@]} ))
  local total_runs=$(( total_configs * ${#benchmarks[@]} ))
  local cfg_idx=0
  local run_idx=0

  prebuild_cache_benchmarks

  for mem in "${MEM_TYPES[@]}"; do
    for (( i=0; i<num_cfgs; i++ )); do
      local ic_en=${IC_EN_LIST[$i]}
      local ic_sz=${IC_SZ_LIST[$i]}
      local ic_wy=${IC_WY_LIST[$i]}
      local ic_ln=${IC_LN_LIST[$i]}
      local dc_en=${DC_EN_LIST[$i]}
      local dc_sz=${DC_SZ_LIST[$i]}
      local dc_wy=${DC_WY_LIST[$i]}
      local dc_ln=${DC_LN_LIST[$i]}

      cfg_idx=$((cfg_idx + 1))

      local ic_label dc_label
      ic_label=$([ "$ic_en" = "1" ] && echo "$((ic_sz/1024))K ${ic_wy}W ${ic_ln}B" || echo "off")
      dc_label=$([ "$dc_en" = "1" ] && echo "$((dc_sz/1024))K ${dc_wy}W ${dc_ln}B" || echo "off")
      echo "=========================================="
      echo "[${cfg_idx}/${total_configs}] MEM=${mem}  IC=${ic_label}  DC=${dc_label}"
      echo "=========================================="

      local rtos_tick
      if [[ "$mem" == ddr4-* ]]; then
        rtos_tick=30000
      elif [[ ( "$ic_en" = "1" && "$ic_sz" -le 2048 ) || ( "$dc_en" = "1" && "$dc_sz" -le 2048 ) ]]; then
        rtos_tick=20000
      else
        rtos_tick=5000
      fi

      local build_log="$RESULTS_DIR/build_${mem}_ic${ic_en}s${ic_sz}dc${dc_en}s${dc_sz}.log"
      echo -n "  Building RTL... "
      if ! make build-rtl \
            ICACHE_EN=${ic_en} ICACHE_SIZE=${ic_sz} ICACHE_WAYS=${ic_wy} ICACHE_LINE_SIZE=${ic_ln} \
            DCACHE_EN=${dc_en} DCACHE_SIZE=${dc_sz} DCACHE_WAYS=${dc_wy} DCACHE_LINE_SIZE=${dc_ln} \
            MEM_TYPE=${mem} VERILATOR_JOBS=${NCPU} \
            > "$build_log" 2>&1; then
        echo "BUILD FAILED — see $build_log"
        run_idx=$((run_idx + ${#benchmarks[@]}))
        continue
      fi
      echo "OK"

      local rtos_elf_log="$RESULTS_DIR/rtos_elf_${mem}_ic${ic_en}.log"
      local extra_rtos_flags=""
      if [[ "$ic_en" = "0" && "$mem" == ddr4-* ]]; then
        extra_rtos_flags="-DMRTOS_T1_RUNS=1 -DMRTOS_T2_START_DELAY=0 -DMRTOS_T2_POST_GAP=0 -DMRTOS_T3_LOW_WORK_SLICES=10 -DMRTOS_T3_MED_START_DELAY=2 -DMRTOS_T3_HIGH_START_DELAY=3 -DMRTOS_T4_ITERS=4"
      fi

      echo -n "  Building rtos.elf (TICK=${rtos_tick})... "
      if ! make -B build/rtos.elf EXTRA_CFLAGS="-DMRTOS_T4_TICK_FAST=${rtos_tick} ${extra_rtos_flags}" > "$rtos_elf_log" 2>&1; then
        echo "RTOS ELF BUILD FAILED — see $rtos_elf_log"
      else
        echo "OK"
      fi

      for bench in "${benchmarks[@]}"; do
        run_idx=$((run_idx + 1))
        local log="$RESULTS_DIR/${bench}_${mem}_ic${ic_en}s${ic_sz}dc${dc_en}s${dc_sz}.log"
        echo -n "  [${run_idx}/${total_runs}] ${bench}... "

        local timeout_s=0
        [[ "$bench" = "rtos" ]] && timeout_s=120
        [[ "$bench" = "cachebench" ]] && timeout_s=240

        local pass_fail="SKIP"
        if [[ "$bench" = "rtos" && ! -f "build/rtos.elf" ]]; then
          echo "SKIP (no rtos.elf)"
        elif run_with_timeout "$timeout_s" bash -c "cd build && ./kv32soc ${bench}.elf" > "$log" 2>&1; then
          pass_fail="PASS"
        else
          local exit_code=$?
          [[ $exit_code -eq 124 ]] && pass_fail="TIMEOUT" || pass_fail="FAIL"
        fi

        parse_metrics "$log"

        echo "${mem},${ic_en},${ic_sz},${ic_wy},${ic_ln},${dc_en},${dc_sz},${dc_wy},${dc_ln},${bench},${pass_fail},${total_cycles},${instructions},${stall_cycles},${stall_pct},${cpi},${ic_hits},${ic_hit_pct},${ic_misses},${ic_fills},${dc_hits},${dc_hit_pct},${dc_misses},${dc_fills}" >> "$csv"

        echo "${pass_fail}  CPI=${cpi}  Stall=${stall_pct}%  IC-hit=${ic_hit_pct}%  DC-hit=${dc_hit_pct}%"
      done
      echo ""
    done
  done

  echo "=========================================="
  echo "Cache sweep complete. Results: $csv"
  echo "=========================================="
  wc -l < "$csv" | awk '{print "Rows:", $1, "(including header)"}'
}

run_predictor_mode() {
  local csv="$RESULTS_DIR/predictor_results.csv"
  echo "mem_type,sweep_axis,sweep_point,bp_en,btb_size,bht_size,ras_en,ras_depth,ic_en,ic_size_B,ic_ways,ic_line_B,dc_en,dc_size_B,dc_ways,dc_line_B,benchmark,pass_fail,total_cycles,instructions,stall_cycles,stall_pct,cpi,ic_hits,ic_hit_pct,ic_misses,ic_fills,dc_hits,dc_hit_pct,dc_misses,dc_fills,bp_branches,bp_jumps,bp_preds,bp_mispreds,bp_accuracy_pct,bp_ras_pushes,bp_ras_pops" > "$csv"

  local ic_en=${PRED_ICACHE_EN:-1}
  local ic_sz=${PRED_ICACHE_SIZE:-8192}
  local ic_wy=${PRED_ICACHE_WAYS:-2}
  local ic_ln=${PRED_ICACHE_LINE_SIZE:-32}
  local dc_en=${PRED_DCACHE_EN:-1}
  local dc_sz=${PRED_DCACHE_SIZE:-8192}
  local dc_wy=${PRED_DCACHE_WAYS:-2}
  local dc_ln=${PRED_DCACHE_LINE_SIZE:-32}

  local bench_workset=64
  local bench_iters_btb=3500
  local bench_iters_bht=5000
  local bench_iters_ras=5000
  if [[ "$QUICK" = "1" ]]; then
    bench_workset=32
    bench_iters_btb=1600
    bench_iters_bht=2200
    bench_iters_ras=1800
  fi

  local benchmarks=("btbbench" "bhtbench" "rasbench")
  prebuild_predictor_benchmarks

  local btb_vals bht_vals ras_vals
  if [[ "$QUICK" = "1" ]]; then
    btb_vals="16 32 64"
    bht_vals="32 64 128"
    ras_vals="4 8 16"
  else
    btb_vals=${BTB_SWEEP:-"8 16 32 64 128"}
    bht_vals=${BHT_SWEEP:-"16 32 64 128 256"}
    ras_vals=${RAS_SWEEP:-"2 4 8 16 32"}
  fi

  local base_btb=${PRED_BASE_BTB:-32}
  local base_bht=${PRED_BASE_BHT:-64}
  local base_ras=${PRED_BASE_RAS:-8}

  local cfg_axis=()
  local cfg_point=()
  local cfg_bp_en=()
  local cfg_btb=()
  local cfg_bht=()
  local cfg_ras_en=()
  local cfg_ras=()

  add_cfg() {
    cfg_axis+=("$1")
    cfg_point+=("$2")
    cfg_bp_en+=("$3")
    cfg_btb+=("$4")
    cfg_bht+=("$5")
    cfg_ras_en+=("$6")
    cfg_ras+=("$7")
  }

  add_cfg "baseline" "bp_off" 0 "$base_btb" "$base_bht" 0 "$base_ras"
  add_cfg "baseline" "default" 1 "$base_btb" "$base_bht" 1 "$base_ras"

  for v in $btb_vals; do
    add_cfg "btb" "$v" 1 "$v" "$base_bht" 1 "$base_ras"
  done
  for v in $bht_vals; do
    add_cfg "bht" "$v" 1 "$base_btb" "$v" 1 "$base_ras"
  done
  for v in $ras_vals; do
    add_cfg "ras" "$v" 1 "$base_btb" "$base_bht" 1 "$v"
  done

  local total_cfgs=${#cfg_axis[@]}
  local total_runs=$(( total_cfgs * ${#MEM_TYPES[@]} * ${#benchmarks[@]} ))
  local cfg_idx=0
  local run_idx=0

  for mem in "${MEM_TYPES[@]}"; do
    for ((i=0; i<total_cfgs; i++)); do
      cfg_idx=$((cfg_idx + 1))
      local axis=${cfg_axis[$i]}
      local point=${cfg_point[$i]}
      local bp_en=${cfg_bp_en[$i]}
      local btb_size=${cfg_btb[$i]}
      local bht_size=${cfg_bht[$i]}
      local ras_en=${cfg_ras_en[$i]}
      local ras_depth=${cfg_ras[$i]}

      echo "=========================================="
      echo "[${cfg_idx}/$((total_cfgs * ${#MEM_TYPES[@]}))] MEM=${mem} AXIS=${axis} POINT=${point} BP=${bp_en} BTB=${btb_size} BHT=${bht_size} RAS=${ras_en}/${ras_depth}"
      echo "=========================================="

      local build_log="$RESULTS_DIR/build_pred_${mem}_${axis}_${point}.log"
      echo -n "  Building RTL... "
      if ! make build-rtl \
            ICACHE_EN=${ic_en} ICACHE_SIZE=${ic_sz} ICACHE_WAYS=${ic_wy} ICACHE_LINE_SIZE=${ic_ln} \
            DCACHE_EN=${dc_en} DCACHE_SIZE=${dc_sz} DCACHE_WAYS=${dc_wy} DCACHE_LINE_SIZE=${dc_ln} \
            BP_EN=${bp_en} BTB_SIZE=${btb_size} BHT_SIZE=${bht_size} RAS_EN=${ras_en} RAS_DEPTH=${ras_depth} \
            MEM_TYPE=${mem} VERILATOR_JOBS=${NCPU} \
            > "$build_log" 2>&1; then
        echo "BUILD FAILED — see $build_log"
        run_idx=$((run_idx + ${#benchmarks[@]}))
        continue
      fi
      echo "OK"

      for bench in "${benchmarks[@]}"; do
        run_idx=$((run_idx + 1))
        local log="$RESULTS_DIR/${bench}_${mem}_${axis}_${point}_bp${bp_en}_btb${btb_size}_bht${bht_size}_ras${ras_depth}.log"
        echo -n "  [${run_idx}/${total_runs}] ${bench}... "

        local extra_flags=""
        if [[ "$bench" = "btbbench" ]]; then
          extra_flags="-DBTBBENCH_WORKSET=${bench_workset} -DBTBBENCH_ITERS=${bench_iters_btb}"
        elif [[ "$bench" = "bhtbench" ]]; then
          extra_flags="-DBHTBENCH_WORKSET=${bench_workset} -DBHTBENCH_PHASES=${bench_iters_bht}"
        elif [[ "$bench" = "rasbench" ]]; then
          extra_flags="-DRASBENCH_DEPTH=24 -DRASBENCH_ITERS=${bench_iters_ras}"
        fi

        if ! make -B "build/${bench}.elf" EXTRA_CFLAGS="$extra_flags" > "$RESULTS_DIR/build_${bench}_${axis}_${point}.log" 2>&1; then
          echo "ELF BUILD FAIL"
          parse_metrics "$RESULTS_DIR/build_${bench}_${axis}_${point}.log"
          echo "${mem},${axis},${point},${bp_en},${btb_size},${bht_size},${ras_en},${ras_depth},${ic_en},${ic_sz},${ic_wy},${ic_ln},${dc_en},${dc_sz},${dc_wy},${dc_ln},${bench},FAIL,${total_cycles},${instructions},${stall_cycles},${stall_pct},${cpi},${ic_hits},${ic_hit_pct},${ic_misses},${ic_fills},${dc_hits},${dc_hit_pct},${dc_misses},${dc_fills},${bp_branches},${bp_jumps},${bp_preds},${bp_mispreds},${bp_accuracy},${bp_ras_pushes},${bp_ras_pops}" >> "$csv"
          continue
        fi

        local pass_fail="SKIP"
        local timeout_s=90
        if run_with_timeout "$timeout_s" bash -c "cd build && ./kv32soc ${bench}.elf" > "$log" 2>&1; then
          pass_fail="PASS"
        else
          local exit_code=$?
          [[ $exit_code -eq 124 ]] && pass_fail="TIMEOUT" || pass_fail="FAIL"
        fi

        parse_metrics "$log"

        echo "${mem},${axis},${point},${bp_en},${btb_size},${bht_size},${ras_en},${ras_depth},${ic_en},${ic_sz},${ic_wy},${ic_ln},${dc_en},${dc_sz},${dc_wy},${dc_ln},${bench},${pass_fail},${total_cycles},${instructions},${stall_cycles},${stall_pct},${cpi},${ic_hits},${ic_hit_pct},${ic_misses},${ic_fills},${dc_hits},${dc_hit_pct},${dc_misses},${dc_fills},${bp_branches},${bp_jumps},${bp_preds},${bp_mispreds},${bp_accuracy},${bp_ras_pushes},${bp_ras_pops}" >> "$csv"

        echo "${pass_fail}  CPI=${cpi}  Stall=${stall_pct}%  Mispreds=${bp_mispreds}  Accuracy=${bp_accuracy}%"
      done
      echo ""
    done
  done

  echo "=========================================="
  echo "Predictor sweep complete. Results: $csv"
  echo "=========================================="
  wc -l < "$csv" | awk '{print "Rows:", $1, "(including header)"}'
}

case "$MODE" in
  cache)
    run_cache_mode
    ;;
  predictor)
    run_predictor_mode
    ;;
  all)
    run_cache_mode
    run_predictor_mode
    ;;
  *)
    echo "ERROR: Unsupported MODE='$MODE' (expected cache|predictor|all)"
    exit 1
    ;;
esac
