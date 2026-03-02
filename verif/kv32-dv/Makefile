# ============================================================================
# Makefile for KV32 riscv-dv Random Instruction Verification
# ============================================================================
#
# Quick Start:
#   make setup           # Clone riscv-dv and install Python dependencies
#   make gen             # Generate random assembly tests
#   make compile         # Compile generated tests
#   make run-iss         # Run on ISS (spike)
#   make run-rtl         # Run on RTL (Verilator)
#   make run             # Full flow: gen → compile → ISS → RTL → compare
#   make clean           # Clean generated output
#
# Options:
#   TEST=kv32_rand_instr    Run specific test
#   ITERATIONS=5            Override iteration count
#   SEED=12345              Set random seed
#   ISS=spike               Choose ISS (spike or kv32sim)
#   MAX_CYCLES=10000000     RTL simulation timeout
# ============================================================================

# Load environment configuration
-include ../../env.config
export RISCV_PREFIX
export SPIKE

# Project paths
PROJECT_ROOT := $(realpath ../..)
KV32_DV_DIR  := $(CURDIR)
SCRIPTS_DIR  := $(KV32_DV_DIR)/scripts
TARGET_DIR   := $(KV32_DV_DIR)/target/kv32
RISCV_DV_DIR := $(KV32_DV_DIR)/riscv-dv
OUTPUT_DIR   := $(KV32_DV_DIR)/out
BUILD_DIR    := $(PROJECT_ROOT)/build

# Python virtual environment (shared with RISCOF)
VENV_DIR     := $(KV32_DV_DIR)/.venv
VENV_ACTIVATE = source $(VENV_DIR)/bin/activate

# Tools
RISCV_PREFIX ?= riscv64-unknown-elf-
RISCV_GCC    := $(RISCV_PREFIX)gcc
SPIKE        ?= spike
KV32SIM      := $(BUILD_DIR)/kv32sim
KV32SOC      := $(BUILD_DIR)/kv32soc
MAX_CYCLES   ?= 10000000

# Test options
TEST         ?=
ITERATIONS   ?=
SEED         ?=
ISS          ?= spike

# Run script options
RUN_OPTS :=
ifneq ($(TEST),)
  RUN_OPTS += --test $(TEST)
endif
ifneq ($(ITERATIONS),)
  RUN_OPTS += --iterations $(ITERATIONS)
endif
ifneq ($(SEED),)
  RUN_OPTS += --seed $(SEED)
endif
RUN_OPTS += --iss $(ISS)
RUN_OPTS += --output $(OUTPUT_DIR)
RUN_OPTS += --riscv-dv $(RISCV_DV_DIR)

# ============================================================================
# Targets
# ============================================================================

.PHONY: all setup gen compile run-iss run-rtl run clean help

all: help

# --------------------------------------------------------------------------
# Setup: Clone riscv-dv and install dependencies
# --------------------------------------------------------------------------
setup:
	@echo "=========================================="
	@echo "Setting up riscv-dv environment"
	@echo "=========================================="
	@if [ ! -d "$(RISCV_DV_DIR)" ]; then \
		echo "Cloning Google riscv-dv..."; \
		git clone https://github.com/chipsalliance/riscv-dv.git $(RISCV_DV_DIR); \
		echo "✓ riscv-dv cloned"; \
	else \
		echo "✓ riscv-dv already present at $(RISCV_DV_DIR)"; \
	fi
	@if [ ! -d "$(VENV_DIR)" ]; then \
		echo "Creating Python virtual environment..."; \
		python3 -m venv $(VENV_DIR); \
	fi
	@echo "Installing riscv-dv Python dependencies..."
	@bash -c "$(VENV_ACTIVATE) && PIP_USER=false pip3 install --quiet --upgrade pip setuptools wheel"
	@bash -c "$(VENV_ACTIVATE) && PIP_USER=false pip3 install --quiet -e $(RISCV_DV_DIR)"
	@echo ""
	@echo "✓ Setup complete!"
	@echo "=========================================="
	@echo ""
	@echo "Next steps:"
	@echo "  make gen              # Generate random tests"
	@echo "  make run              # Full flow (gen → compile → ISS → RTL → compare)"
	@echo "  make run TEST=kv32_arithmetic_basic  # Run a specific test"
	@echo "=========================================="

# --------------------------------------------------------------------------
# Generate random assembly
# --------------------------------------------------------------------------
gen: _check_riscv_dv
	@echo "=== Generating random assembly ==="
	@bash -c "$(VENV_ACTIVATE) && $(SCRIPTS_DIR)/run.sh $(RUN_OPTS) --gen-only"

# --------------------------------------------------------------------------
# Compile generated assembly
# --------------------------------------------------------------------------
compile: _check_riscv_dv
	@echo "=== Compiling generated tests ==="
	@bash -c "$(VENV_ACTIVATE) && $(SCRIPTS_DIR)/run.sh $(RUN_OPTS) --compile-only"

# --------------------------------------------------------------------------
# Run on ISS
# --------------------------------------------------------------------------
run-iss: _check_riscv_dv
	@echo "=== Running on ISS ==="
	@bash -c "$(VENV_ACTIVATE) && $(SCRIPTS_DIR)/run.sh $(RUN_OPTS) --no-rtl"

# --------------------------------------------------------------------------
# Run on RTL
# --------------------------------------------------------------------------
run-rtl: _check_rtl
	@echo "=== Running on RTL ==="
	@# This triggers the full flow but we want to ensure RTL is built
	@$(MAKE) -C $(PROJECT_ROOT) build-rtl
	@bash -c "$(VENV_ACTIVATE) && $(SCRIPTS_DIR)/run.sh $(RUN_OPTS)"

# --------------------------------------------------------------------------
# Full flow: gen → compile → ISS → RTL → compare
# --------------------------------------------------------------------------
run: _check_riscv_dv _check_rtl
	@bash -c "$(VENV_ACTIVATE) && $(SCRIPTS_DIR)/run.sh $(RUN_OPTS)"

# --------------------------------------------------------------------------
# Internal checks
# --------------------------------------------------------------------------
.PHONY: _check_riscv_dv _check_rtl

_check_riscv_dv:
	@if [ ! -d "$(RISCV_DV_DIR)" ]; then \
		echo "ERROR: riscv-dv not found. Run 'make setup' first."; \
		exit 1; \
	fi
	@if [ ! -d "$(VENV_DIR)" ]; then \
		echo "ERROR: Python venv not found. Run 'make setup' first."; \
		exit 1; \
	fi

_check_rtl:
	@if [ ! -x "$(KV32SOC)" ]; then \
		echo "Building RTL simulation binary..."; \
		$(MAKE) -C $(PROJECT_ROOT) build-rtl; \
	fi

# --------------------------------------------------------------------------
# Clean
# --------------------------------------------------------------------------
clean:
	@echo "Cleaning riscv-dv output..."
	@rm -rf $(OUTPUT_DIR)
	@echo "✓ Cleaned"

clean-all: clean
	@echo "Removing riscv-dv clone and Python venv..."
	@rm -rf $(RISCV_DV_DIR)
	@rm -rf $(VENV_DIR)
	@echo "✓ Fully cleaned"

# --------------------------------------------------------------------------
# Help
# --------------------------------------------------------------------------
help:
	@echo "=========================================="
	@echo "KV32 riscv-dv Random Instruction Tests"
	@echo "=========================================="
	@echo ""
	@echo "Setup (one-time):"
	@echo "  make setup              Clone riscv-dv and install dependencies"
	@echo ""
	@echo "Run Tests:"
	@echo "  make run                Full flow: gen → compile → ISS → RTL → compare"
	@echo "  make gen                Generate random assembly only"
	@echo "  make compile            Generate and compile (no run)"
	@echo "  make run-iss            Generate, compile, run on ISS only"
	@echo "  make run-rtl            Full flow including RTL"
	@echo ""
	@echo "Options:"
	@echo "  TEST=<name>             Run specific test (e.g., kv32_arithmetic_basic)"
	@echo "  ITERATIONS=<n>          Override iteration count"
	@echo "  SEED=<n>                Set random seed for reproducibility"
	@echo "  ISS=<spike|kv32sim>     Choose ISS (default: spike)"
	@echo "  MAX_CYCLES=<n>          RTL simulation timeout (default: 10000000)"
	@echo ""
	@echo "Available Tests (from testlist.yaml):"
	@echo "  kv32_arithmetic_basic   Basic I-type arithmetic/logic"
	@echo "  kv32_mul_div            M-extension (mul/div)"
	@echo "  kv32_amo                A-extension (atomics)"
	@echo "  kv32_branch_jump        Branch and jump coverage"
	@echo "  kv32_load_store         Load/store coverage"
	@echo "  kv32_csr                CSR operations"
	@echo "  kv32_rand_instr         Random mixed instructions"
	@echo "  kv32_machine_mode_trap  Trap handling (ecall/ebreak)"
	@echo "  kv32_hint_nop           HINT/NOP sequences"
	@echo "  kv32_rand_stress        Large stress test"
	@echo ""
	@echo "Examples:"
	@echo "  make setup"
	@echo "  make run TEST=kv32_arithmetic_basic SEED=42"
	@echo "  make run ISS=kv32sim"
	@echo "  make gen TEST=kv32_rand_instr ITERATIONS=10"
	@echo ""
	@echo "Clean:"
	@echo "  make clean              Remove generated output"
	@echo "  make clean-all          Remove output + riscv-dv clone + venv"
	@echo "=========================================="
