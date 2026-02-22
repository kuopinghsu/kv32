#!/bin/bash
# Debug script for RISCOF architecture tests
# Enables tracing and debug output for failing tests
# Usage: ./debug-arch-test.sh [test_name]
#   test_name - optional test to debug (e.g., beq-01)
#              If not specified, runs all RV32I tests with debug enabled

set -e

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../" && pwd)
VERIF_DIR="$PROJECT_ROOT/verif/riscof_targets"

echo "=========================================="
echo "RISCOF Architecture Test - Debug Mode"
echo "=========================================="
echo "Project Root: $PROJECT_ROOT"
echo "Debug Mode: ENABLED"
echo ""

# Enable debug mode
export RISCOF_DEBUG=1

# Check if test name provided
if [ -n "$1" ]; then
    TEST_NAME="$1"
    echo "Running single test: $TEST_NAME"
    echo "To examine results, check: $PROJECT_ROOT/verif/riscof_targets/riscof_work/"
    echo ""

    # Run RISCOF with single test pattern
    cd "$PROJECT_ROOT"
    python3 -m riscof run \
        --config="$VERIF_DIR/config_rtl.ini" \
        --suite="$PROJECT_ROOT/verif/riscv-arch-test/riscv-test-suite" \
        --env="$PROJECT_ROOT/verif/riscv-arch-test/riscv-test-suite/env" \
        --work-dir="$VERIF_DIR/riscof_work" \
        --testfilter="$TEST_NAME" \
        2>&1 | tee arch-test-debug.log
else
    echo "Running all RV32I architecture tests with debug output enabled"
    echo "This will enable RTL tracing for each test"
    echo "Debug outputs will be saved in test work directories"
    echo ""

    # Run full RISCOF tests
    cd "$PROJECT_ROOT"
    make arch-test-rv32i 2>&1 | tee arch-test-debug.log
fi

echo ""
echo "=========================================="
echo "Debug run completed!"
echo "=========================================="
echo ""
echo "To view debug output:"
echo "  - RTL traces: $PROJECT_ROOT/verif/riscof_targets/riscof_work/*/debug_output/*_rtl_trace.txt"
echo "  - Sim logs:   $PROJECT_ROOT/verif/riscof_targets/riscof_work/*/debug_output/*_sim.log"
echo "  - Full log:   $PROJECT_ROOT/arch-test-debug.log"
echo ""
