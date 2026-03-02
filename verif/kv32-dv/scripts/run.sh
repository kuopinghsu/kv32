#!/usr/bin/env bash
# ============================================================================
# File: run.sh
# Project: KV32 RISC-V Processor — riscv-dv
# Description: End-to-end script to generate random tests with riscv-dv,
#              compile them for the KV32 SoC, run on ISS + RTL, and compare
#              instruction traces.
#
# Prerequisites:
#   - Python 3.6+ with riscv-dv installed (pip install .)
#   - RISC-V GCC toolchain
#   - Spike ISA simulator (for reference comparison)
#   - Verilator RTL simulation binary (built by project Makefile)
#
# Usage:
#   ./run.sh [OPTIONS]
#
# Options:
#   --test <name>         Run specific test from testlist.yaml (default: all)
#   --iterations <n>      Override iteration count (default: from testlist)
#   --seed <n>            Random seed (default: random)
#   --iss <spike|kv32sim> ISS for comparison (default: spike)
#   --gen-only            Generate assembly only (no compile/run)
#   --compile-only        Generate + compile only (no run)
#   --no-rtl              Skip RTL simulation (ISS only)
#   --output <dir>        Output directory (default: out/)
#   --riscv-dv <path>     Path to riscv-dv checkout (default: ../riscv-dv)
#   --help                Show this help
# ============================================================================

set -euo pipefail

# ============================================================================
# Default Configuration
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KV32_DV_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${KV32_DV_DIR}/../.." && pwd)"

# Paths
RISCV_DV_DIR="${KV32_DV_DIR}/riscv-dv"
TARGET_DIR="${KV32_DV_DIR}/target/kv32"
OUTPUT_DIR="${KV32_DV_DIR}/out"
BUILD_DIR="${PROJECT_ROOT}/build"

# Tools (from env.config or environment)
if [[ -f "${PROJECT_ROOT}/env.config" ]]; then
    # shellcheck source=/dev/null
    source <(grep -E '^(RISCV_PREFIX|SPIKE|VERILATOR)=' "${PROJECT_ROOT}/env.config" | sed 's/^/export /')
fi
RISCV_PREFIX="${RISCV_PREFIX:-riscv64-unknown-elf-}"
RISCV_GCC="${RISCV_PREFIX}gcc"
RISCV_OBJCOPY="${RISCV_PREFIX}objcopy"
RISCV_OBJDUMP="${RISCV_PREFIX}objdump"
SPIKE="${SPIKE:-spike}"
KV32SIM="${BUILD_DIR}/kv32sim"
KV32SOC="${BUILD_DIR}/kv32soc"
MAX_CYCLES="${MAX_CYCLES:-10000000}"

# Options
TEST_NAME=""
ITERATIONS=""
SEED=""
ISS="spike"
GEN_ONLY=0
COMPILE_ONLY=0
NO_RTL=0

# ============================================================================
# Parse Arguments
# ============================================================================
usage() {
    head -n 35 "$0" | grep -E '^\s*#' | sed 's/^#\s\?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --test)        TEST_NAME="$2"; shift 2 ;;
        --iterations)  ITERATIONS="$2"; shift 2 ;;
        --seed)        SEED="$2"; shift 2 ;;
        --iss)         ISS="$2"; shift 2 ;;
        --gen-only)    GEN_ONLY=1; shift ;;
        --compile-only) COMPILE_ONLY=1; shift ;;
        --no-rtl)      NO_RTL=1; shift ;;
        --output)      OUTPUT_DIR="$2"; shift 2 ;;
        --riscv-dv)    RISCV_DV_DIR="$2"; shift 2 ;;
        --help|-h)     usage ;;
        *)             echo "Unknown option: $1"; usage ;;
    esac
done

# ============================================================================
# Validate Environment
# ============================================================================
echo "=========================================="
echo "KV32 riscv-dv Random Instruction Test"
echo "=========================================="

# Check riscv-dv
if [[ ! -d "${RISCV_DV_DIR}" ]]; then
    echo "ERROR: riscv-dv not found at ${RISCV_DV_DIR}"
    echo ""
    echo "Please clone Google riscv-dv:"
    echo "  cd ${KV32_DV_DIR}"
    echo "  git clone https://github.com/chipsalliance/riscv-dv.git"
    echo ""
    echo "Or specify the path:"
    echo "  $0 --riscv-dv /path/to/riscv-dv"
    exit 1
fi

# Check toolchain
if ! command -v "${RISCV_GCC}" &>/dev/null; then
    echo "ERROR: RISC-V GCC not found: ${RISCV_GCC}"
    echo "Set RISCV_PREFIX in env.config or environment"
    exit 1
fi

# Check ISS
case "${ISS}" in
    spike)
        if ! command -v "${SPIKE}" &>/dev/null; then
            echo "ERROR: Spike not found: ${SPIKE}"
            exit 1
        fi
        ;;
    kv32sim)
        if [[ ! -x "${KV32SIM}" ]]; then
            echo "Building kv32sim..."
            make -C "${PROJECT_ROOT}/sim" || { echo "ERROR: Failed to build kv32sim"; exit 1; }
        fi
        ;;
    *)
        echo "ERROR: Unknown ISS: ${ISS} (supported: spike, kv32sim)"
        exit 1
        ;;
esac

echo "  riscv-dv:   ${RISCV_DV_DIR}"
echo "  Target:     ${TARGET_DIR}"
echo "  GCC:        ${RISCV_GCC}"
echo "  ISS:        ${ISS}"
echo "  Output:     ${OUTPUT_DIR}"
echo ""

mkdir -p "${OUTPUT_DIR}"

# ============================================================================
# Step 1: Generate Random Assembly
# ============================================================================
echo "=== Step 1: Generate Random Assembly ==="

GEN_CMD=(
    python3 "${RISCV_DV_DIR}/run.py"
    --target kv32
    --custom_target "${TARGET_DIR}"
    --output "${OUTPUT_DIR}/gen"
    --testlist "${TARGET_DIR}/testlist.yaml"
    --simulator pyflow
    --mabi ilp32
    --isa rv32ima
    --start_idx 0
    --end_idx 0
    --steps gen
)

if [[ -n "${TEST_NAME}" ]]; then
    GEN_CMD+=(--test "${TEST_NAME}")
fi

if [[ -n "${ITERATIONS}" ]]; then
    GEN_CMD+=(--iterations "${ITERATIONS}")
fi

if [[ -n "${SEED}" ]]; then
    GEN_CMD+=(--seed "${SEED}")
fi

echo "Running: ${GEN_CMD[*]}"
"${GEN_CMD[@]}" || { echo "ERROR: Assembly generation failed"; exit 1; }
echo ""

if [[ "${GEN_ONLY}" -eq 1 ]]; then
    echo "=== Generation complete (--gen-only) ==="
    echo "Generated assembly: ${OUTPUT_DIR}/gen/asm_test/"
    exit 0
fi

# ============================================================================
# Step 2: Compile Generated Assembly
# ============================================================================
echo "=== Step 2: Compile Generated Assembly ==="

ASM_DIR="${OUTPUT_DIR}/gen/asm_test"
BIN_DIR="${OUTPUT_DIR}/bin"
mkdir -p "${BIN_DIR}"

COMPILE_FLAGS=(
    -march=rv32ima
    -mabi=ilp32
    -nostdlib
    -nostartfiles
    -T "${TARGET_DIR}/link.ld"
    -I "${RISCV_DV_DIR}/user_extension"
)

compile_count=0
for asm_file in "${ASM_DIR}"/*/*.S; do
    [[ -f "${asm_file}" ]] || continue
    test_name="$(basename "$(dirname "${asm_file}")")"
    elf_file="${BIN_DIR}/${test_name}.elf"
    bin_file="${BIN_DIR}/${test_name}.bin"

    echo "  Compiling: ${test_name}"
    "${RISCV_GCC}" "${COMPILE_FLAGS[@]}" -o "${elf_file}" "${asm_file}" || {
        echo "  WARNING: Failed to compile ${test_name}, skipping"
        continue
    }
    "${RISCV_OBJCOPY}" -O binary "${elf_file}" "${bin_file}" 2>/dev/null || true
    "${RISCV_OBJDUMP}" -d "${elf_file}" > "${BIN_DIR}/${test_name}.dis" 2>/dev/null || true
    compile_count=$((compile_count + 1))
done

echo "  Compiled ${compile_count} test(s)"
echo ""

if [[ "${COMPILE_ONLY}" -eq 1 ]]; then
    echo "=== Compile complete (--compile-only) ==="
    echo "ELF files: ${BIN_DIR}/"
    exit 0
fi

# ============================================================================
# Step 3: Run on ISS (Reference)
# ============================================================================
echo "=== Step 3: Run on ISS (${ISS}) ==="

ISS_DIR="${OUTPUT_DIR}/iss"
mkdir -p "${ISS_DIR}"

iss_count=0
for elf_file in "${BIN_DIR}"/*.elf; do
    [[ -f "${elf_file}" ]] || continue
    test_name="$(basename "${elf_file}" .elf)"
    iss_log="${ISS_DIR}/${test_name}.log"

    echo "  Running ISS: ${test_name}"
    case "${ISS}" in
        spike)
            "${SPIKE}" --isa=rv32ima -m0x80000000:0x200000 \
                -l --log-commits "${elf_file}" \
                > "${iss_log}" 2>&1 || true
            # Convert to CSV trace
            python3 "${SCRIPT_DIR}/spike2trace.py" \
                --log "${iss_log}" \
                --csv "${ISS_DIR}/${test_name}_trace.csv" || true
            ;;
        kv32sim)
            "${KV32SIM}" --trace "${elf_file}" \
                > "${iss_log}" 2>&1 || true
            python3 "${SCRIPT_DIR}/kv32sim2trace.py" \
                --log "${iss_log}" \
                --csv "${ISS_DIR}/${test_name}_trace.csv" || true
            ;;
    esac
    iss_count=$((iss_count + 1))
done

echo "  Ran ${iss_count} test(s) on ${ISS}"
echo ""

# ============================================================================
# Step 4: Run on RTL (Verilator)
# ============================================================================
if [[ "${NO_RTL}" -eq 1 ]]; then
    echo "=== Skipping RTL simulation (--no-rtl) ==="
else
    echo "=== Step 4: Run on RTL (Verilator) ==="

    # Build RTL if needed
    if [[ ! -x "${KV32SOC}" ]]; then
        echo "  Building RTL simulation binary..."
        make -C "${PROJECT_ROOT}" build-rtl || { echo "ERROR: RTL build failed"; exit 1; }
    fi

    RTL_DIR="${OUTPUT_DIR}/rtl"
    mkdir -p "${RTL_DIR}"

    rtl_count=0
    for elf_file in "${BIN_DIR}"/*.elf; do
        [[ -f "${elf_file}" ]] || continue
        test_name="$(basename "${elf_file}" .elf)"
        rtl_log="${RTL_DIR}/${test_name}.log"

        echo "  Running RTL: ${test_name}"
        "${KV32SOC}" "+ELF=${elf_file}" "+MAX_CYCLES=${MAX_CYCLES}" "+TRACE" \
            > "${rtl_log}" 2>&1 || {
            echo "  WARNING: RTL simulation failed for ${test_name}"
            continue
        }
        rtl_count=$((rtl_count + 1))
    done

    echo "  Ran ${rtl_count} test(s) on RTL"
    echo ""
fi

# ============================================================================
# Step 5: Compare Traces
# ============================================================================
echo "=== Step 5: Compare Traces ==="

pass_count=0
fail_count=0
skip_count=0

for iss_csv in "${ISS_DIR}"/*_trace.csv; do
    [[ -f "${iss_csv}" ]] || continue
    test_name="$(basename "${iss_csv}" _trace.csv)"

    if [[ "${NO_RTL}" -eq 1 ]]; then
        echo "  [SKIP] ${test_name} (no RTL trace)"
        skip_count=$((skip_count + 1))
        continue
    fi

    rtl_log="${RTL_DIR}/${test_name}.log"
    if [[ ! -f "${rtl_log}" ]]; then
        echo "  [SKIP] ${test_name} (no RTL log)"
        skip_count=$((skip_count + 1))
        continue
    fi

    # Use project's trace_compare.py if available
    if [[ -f "${PROJECT_ROOT}/scripts/trace_compare.py" ]]; then
        compare_log="${OUTPUT_DIR}/compare_${test_name}.log"
        python3 "${PROJECT_ROOT}/scripts/trace_compare.py" \
            "${iss_csv}" "${rtl_log}" > "${compare_log}" 2>&1 || true

        if grep -q "TRACE_MATCH\|PASS\|Match" "${compare_log}" 2>/dev/null; then
            echo "  [PASS] ${test_name}"
            pass_count=$((pass_count + 1))
        else
            echo "  [FAIL] ${test_name} (see ${compare_log})"
            fail_count=$((fail_count + 1))
        fi
    else
        echo "  [INFO] ${test_name} — trace comparison script not found; manual review needed"
        skip_count=$((skip_count + 1))
    fi
done

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=========================================="
echo "Summary"
echo "=========================================="
echo "  Tests compiled:   ${compile_count}"
echo "  ISS runs:         ${iss_count}"
if [[ "${NO_RTL}" -ne 1 ]]; then
    echo "  RTL runs:         ${rtl_count}"
fi
echo "  Trace PASS:       ${pass_count}"
echo "  Trace FAIL:       ${fail_count}"
echo "  Trace SKIP:       ${skip_count}"
echo ""
echo "  Output:           ${OUTPUT_DIR}"
echo "  Generated ASM:    ${ASM_DIR}"
echo "  ELF binaries:     ${BIN_DIR}"
echo "  ISS traces:       ${ISS_DIR}"
if [[ "${NO_RTL}" -ne 1 ]]; then
    echo "  RTL traces:       ${RTL_DIR}"
fi
echo "=========================================="

if [[ "${fail_count}" -gt 0 ]]; then
    exit 1
fi
exit 0
