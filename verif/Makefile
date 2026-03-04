# ============================================================================
# RISC-V Architecture Test Makefile
# ============================================================================
# This Makefile runs RISCOF architectural compliance tests for the kv32 processor.
# 
# Quick Start:
#   make arch-test-setup      - Set up RISCOF environment (one-time)
#   make arch-test-rv32i      - Run RV32I base instruction tests
#   make arch-test-report     - View test results in browser
#
# See 'make arch-test-info' for detailed help

# ============================================================================
# Configuration
# ============================================================================

# Load parent environment configuration
-include ../env.config

# Export environment variables
export RISCV_PREFIX
export VERILATOR
export SPIKE

# Project directories (relative to project root)
PROJECT_ROOT = $(realpath ..)
BUILD_DIR = $(PROJECT_ROOT)/build
SIM_DIR = $(PROJECT_ROOT)/sim
RTL_DIR = $(PROJECT_ROOT)/rtl
CORE_DIR = $(RTL_DIR)/core
TB_DIR = $(PROJECT_ROOT)/testbench

# RISCOF directories (relative to verif/)
RISCOF_DIR = riscof_targets
RISCOF_WORK = $(RISCOF_DIR)/riscof_work
RISCOF_VENV = $(CURDIR)/.venv
RISCOF_ACTIVATE = source $(RISCOF_VENV)/bin/activate

# RISCOF debug mode (set RISCOF_DEBUG=--verbose info for detailed output)
RISCOF_DEBUG ?=

# Trace comparison mode: when TRACE=1 (passed from parent or command line)
# each test also runs kv32sim + kv32soc to generate per-test instruction traces
# that are compared with trace_compare.py after RISCOF signature checking.
TRACE ?= 0
ifeq ($(TRACE),1)
  export ARCH_TEST_TRACE = 1
else
  export ARCH_TEST_TRACE = 0
endif

# Reusable shell snippet: scan riscof_work for per-test trace comparison logs
# and print a PASS/FAIL summary.  Called at the end of arch-test-* targets.
define TRACE_SUMMARY
	@if [ "$(ARCH_TEST_TRACE)" = "1" ]; then \
		echo ""; \
		echo "=== Per-test Trace Comparison Summary ==="; \
		_pass=0; _fail=0; \
		for f in $$(find $(RISCOF_WORK)/src -path "*/dut/trace_compare.log" 2>/dev/null | sort); do \
			_tname=$$(basename $$(dirname $$(dirname $$f))); \
			_testdir=$$(dirname $$(dirname $$f)); \
			if grep -q "^TRACE_MATCH$$" $$f 2>/dev/null; then \
				echo "  [PASS] $$_tname"; \
				_pass=$$((_pass+1)); \
			else \
				echo "  [FAIL] $$_tname  (see $$_testdir/dut/DUT-*.trace)"; \
				_fail=$$((_fail+1)); \
			fi; \
		done; \
		if [ $$((_pass+_fail)) -eq 0 ]; then \
			echo "  (no trace comparison logs found — was TRACE=1 used on a TRACE-enabled build?)"; \
		else \
			echo ""; \
			echo "  Trace match: $$_pass / $$((_pass+_fail))"; \
			if [ "$$_fail" -gt 0 ]; then \
				echo "  WARNING: $$_fail test(s) have trace mismatches"; \
			fi; \
		fi; \
		echo "=========================================="; \
	fi
endef

# Verilator configuration
VERILATOR ?= verilator

# Output executable
BUILD_TARGET = $(BUILD_DIR)/kv32soc

# ============================================================================
# Build Targets
# ============================================================================

.PHONY: all build-rtl clean help

# Default target
all: arch-test-info

# Build RTL via project root Makefile
build-rtl:
	@$(MAKE) -C $(PROJECT_ROOT) build-rtl

# Clean build artifacts (delegates to root)
clean:
	@$(MAKE) -C $(PROJECT_ROOT) clean

# ============================================================================
# RISCOF Architectural Compliance Tests
# ============================================================================

.PHONY: arch-test-setup
arch-test-setup:
	@echo "=========================================="
	@echo "Setting up RISCOF environment"
	@echo "=========================================="
	@if [ ! -d "$(RISCOF_VENV)" ]; then \
		echo "Creating Python virtual environment at $(RISCOF_VENV)..."; \
		python3 -m venv $(RISCOF_VENV); \
		echo "Installing RISCOF..."; \
		bash -c "$(RISCOF_ACTIVATE) && PIP_USER=false pip3 install --quiet --upgrade pip setuptools wheel"; \
		bash -c "$(RISCOF_ACTIVATE) && PIP_USER=false pip3 install --quiet git+https://github.com/riscv/riscof.git@d38859f85fe407bcacddd2efcd355ada4683aee4"; \
		echo "✓ RISCOF installed"; \
	else \
		echo "✓ Virtual environment already exists at $(RISCOF_VENV)"; \
	fi
	@echo ""
	@echo "=== Building kv32sim reference simulator ==="
	@$(MAKE) -C $(SIM_DIR) clean
	@$(MAKE) -C $(SIM_DIR)
	@if [ -f "$(BUILD_DIR)/kv32sim" ]; then \
		echo "✓ kv32sim built successfully: $(BUILD_DIR)/kv32sim"; \
	else \
		echo "⚠ Warning: kv32sim build failed"; \
	fi
	@echo ""
	@echo "=== RISCOF version ==="
	@bash -c "$(RISCOF_ACTIVATE) && riscof --version"
	@echo ""
	@echo "=========================================="
	@echo "✓ Setup complete!"
	@echo "=========================================="
	@echo "Reference models available:"
	@echo "  - spike (default): Official RISC-V ISA simulator"
	@echo "  - kv32sim: kv32 software simulator (built)"
	@echo ""
	@echo "Next steps:"
	@echo "  make arch-test-validate    - Validate configuration"
	@echo "  make arch-test-rv32i       - Run RV32I tests"
	@echo "  make arch-test-info        - Show detailed help"
	@echo "=========================================="

.PHONY: arch-test-validate
arch-test-validate: arch-test-setup
	@echo "=========================================="
	@echo "Validating RISCOF configuration"
	@echo "=========================================="
	@echo "Validating RTL configuration (kv32 vs spike)..."
	@cd $(RISCOF_DIR) && bash -c "$(RISCOF_ACTIVATE) && riscof validateyaml --config=config_rtl.ini"
	@echo ""
	@echo "Validating simulator configuration (kv32sim vs spike)..."
	@cd $(RISCOF_DIR) && bash -c "$(RISCOF_ACTIVATE) && riscof validateyaml --config=config_sim.ini"
	@echo ""
	@echo "✓ Configuration validation complete"
	@echo "=========================================="

.PHONY: arch-test-build
arch-test-build:
	@$(MAKE) -C $(PROJECT_ROOT) build-rtl
	@echo "✓ Verilator simulation binary ready for architectural tests"

.PHONY: arch-test-rv32i
arch-test-rv32i: arch-test-setup arch-test-build
	@echo "=========================================="
	@echo "Running RV32I Architecture Tests (RTL)"
	@echo "=========================================="
	@mkdir -p $(RISCOF_WORK)
	@cd $(RISCOF_DIR) && bash -c "$(RISCOF_ACTIVATE) && riscof $(RISCOF_DEBUG) run --config=config_rtl.ini --suite=../riscv-arch-test/riscv-test-suite/rv32i_m/I --env=../riscv-arch-test/riscv-test-suite/env --work-dir=riscof_work --no-browser"
	@echo ""
	@echo "=========================================="
	@echo "✓ RV32I tests complete"
	@echo "Report: $(RISCOF_WORK)/report.html"
	@echo "=========================================="
	$(TRACE_SUMMARY)

.PHONY: arch-test-rv32m
arch-test-rv32m: arch-test-setup arch-test-build
	@echo "=========================================="
	@echo "Running RV32M Architecture Tests (RTL)"
	@echo "=========================================="
	@mkdir -p $(RISCOF_WORK)
	@cd $(RISCOF_DIR) && bash -c "$(RISCOF_ACTIVATE) && riscof $(RISCOF_DEBUG) run --config=config_rtl.ini --suite=../riscv-arch-test/riscv-test-suite/rv32i_m/M --env=../riscv-arch-test/riscv-test-suite/env --work-dir=riscof_work --no-browser"
	@echo ""
	@echo "=========================================="
	@echo "✓ RV32M tests complete"
	@echo "Report: $(RISCOF_WORK)/report.html"
	@echo "=========================================="
	$(TRACE_SUMMARY)

.PHONY: arch-test-rv32a
arch-test-rv32a: arch-test-setup arch-test-build
	@echo "=========================================="
	@echo "Running RV32A Architecture Tests (RTL)"
	@echo "=========================================="
	@mkdir -p $(RISCOF_WORK)
	@cd $(RISCOF_DIR) && bash -c "$(RISCOF_ACTIVATE) && riscof $(RISCOF_DEBUG) run --config=config_rtl.ini --suite=../riscv-arch-test/riscv-test-suite/rv32i_m/A --env=../riscv-arch-test/riscv-test-suite/env --work-dir=riscof_work --no-browser"
	@echo ""
	@echo "=========================================="
	@echo "✓ RV32A tests complete"
	@echo "Report: $(RISCOF_WORK)/report.html"
	@echo "=========================================="
	$(TRACE_SUMMARY)

.PHONY: arch-test-rv32zicsr
arch-test-rv32zicsr: arch-test-setup arch-test-build
	@echo "=========================================="
	@echo "Running Zicsr Architecture Tests (RTL)"
	@echo "=========================================="
	@mkdir -p $(RISCOF_WORK)
	@cd $(RISCOF_DIR) && bash -c "$(RISCOF_ACTIVATE) && riscof $(RISCOF_DEBUG) run --config=config_rtl.ini --suite=../riscv-arch-test/riscv-test-suite/rv32i_m/privilege --env=../riscv-arch-test/riscv-test-suite/env --work-dir=riscof_work --no-browser"
	@echo ""
	@echo "=========================================="
	@echo "✓ Zicsr tests complete"
	@echo "Report: $(RISCOF_WORK)/report.html"
	@echo "=========================================="
	$(TRACE_SUMMARY)

.PHONY: arch-test-all
arch-test-all: arch-test-rv32i arch-test-rv32m arch-test-rv32a arch-test-rv32zicsr
	@echo "=========================================="
	@echo "✓ All RTL architectural tests complete"
	@echo "=========================================="
	@echo "View report: $(RISCOF_WORK)/report.html"
	@echo "Use 'make arch-test-report' to open in browser"
	@echo "=========================================="

# ============================================================================
# kv32sim Validation Tests (DUT=kv32sim, REF=spike)
# ============================================================================

.PHONY: arch-test-sim
arch-test-sim: arch-test-setup
	@echo "========================================================================"
	@echo "kv32sim Architectural Validation (DUT=kv32sim, REF=spike)"
	@echo "========================================================================"
	@if [ ! -f "$(BUILD_DIR)/kv32sim" ]; then \
		echo "Building kv32sim..."; \
		$(MAKE) -C $(SIM_DIR) || { echo "Error: Failed to build kv32sim"; exit 1; }; \
	fi
	@if [ ! -f "$(RISCOF_DIR)/config_sim.ini" ]; then \
		echo "Error: config_sim.ini not found"; \
		exit 1; \
	fi
	@echo ""
	@echo "=== Running RV32I tests with kv32sim ==="
	@mkdir -p $(RISCOF_WORK)
	@cd $(RISCOF_DIR) && bash -c "$(RISCOF_ACTIVATE) && riscof run --config=config_sim.ini --suite=../riscv-arch-test/riscv-test-suite/rv32i_m/I --env=../riscv-arch-test/riscv-test-suite/env --work-dir=riscof_work --no-browser"
	@echo "✓ RV32I tests complete"
	$(TRACE_SUMMARY)
	@echo ""
	@echo "=== Running RV32M tests with kv32sim ==="
	@cd $(RISCOF_DIR) && bash -c "$(RISCOF_ACTIVATE) && riscof run --config=config_sim.ini --suite=../riscv-arch-test/riscv-test-suite/rv32i_m/M --env=../riscv-arch-test/riscv-test-suite/env --work-dir=riscof_work --no-browser"
	@echo "✓ RV32M tests complete"
	$(TRACE_SUMMARY)
	@echo ""
	@echo "=== Running RV32A tests with kv32sim ==="
	@cd $(RISCOF_DIR) && bash -c "$(RISCOF_ACTIVATE) && riscof run --config=config_sim.ini --suite=../riscv-arch-test/riscv-test-suite/rv32i_m/A --env=../riscv-arch-test/riscv-test-suite/env --work-dir=riscof_work --no-browser"
	@echo "✓ RV32A tests complete"
	$(TRACE_SUMMARY)
	@echo ""
	@echo "=== Running Zicsr tests with kv32sim ==="
	@cd $(RISCOF_DIR) && bash -c "$(RISCOF_ACTIVATE) && riscof run --config=config_sim.ini --suite=../riscv-arch-test/riscv-test-suite/rv32i_m/privilege --env=../riscv-arch-test/riscv-test-suite/env --work-dir=riscof_work --no-browser"
	@echo "✓ Zicsr tests complete"
	$(TRACE_SUMMARY)
	@echo ""
	@echo "=== Running RV32C (Compressed) tests with kv32sim ==="
	@cd $(RISCOF_DIR) && bash -c "$(RISCOF_ACTIVATE) && riscof run --config=config_sim.ini --suite=../riscv-arch-test/riscv-test-suite/rv32i_m/C --env=../riscv-arch-test/riscv-test-suite/env --work-dir=riscof_work --no-browser"
	@echo "✓ RV32C tests complete"
	@echo ""
	@echo "========================================================================"
	@echo "✓ kv32sim Validation Complete"
	@echo "========================================================================"
	@echo "Report: $(RISCOF_WORK)/report.html"
	$(TRACE_SUMMARY)

# ============================================================================
# Report and Cleanup
# ============================================================================

.PHONY: arch-test-report
arch-test-report:
	@if [ -f "$(RISCOF_WORK)/report.html" ]; then \
		echo "Opening test report..."; \
		if command -v open > /dev/null 2>&1; then \
			open $(RISCOF_WORK)/report.html; \
		elif command -v xdg-open > /dev/null 2>&1; then \
			xdg-open $(RISCOF_WORK)/report.html; \
		elif command -v firefox > /dev/null 2>&1; then \
			firefox $(RISCOF_WORK)/report.html; \
		else \
			echo "Report location: $(RISCOF_WORK)/report.html"; \
			echo "Please open this file in your browser"; \
		fi; \
	else \
		echo "Error: No report found."; \
		echo "Run architectural tests first:"; \
		echo "  make arch-test-rv32i"; \
		echo "  make arch-test-all"; \
	fi

.PHONY: arch-test-clean
arch-test-clean:
	@echo "Cleaning RISCOF work directory and test artifacts..."
	@rm -rf $(RISCOF_WORK)
	@echo "✓ RISCOF work directory cleaned"

.PHONY: arch-test-clean-all
arch-test-clean-all: arch-test-clean
	@echo "Removing RISCOF virtual environment..."
	@rm -rf $(RISCOF_VENV)
	@echo "✓ RISCOF environment cleaned"

# ============================================================================
# Help and Information
# ============================================================================

.PHONY: arch-test-info help
arch-test-info help:
	@echo "=========================================="
	@echo "RISCOF Architectural Compliance Tests"
	@echo "=========================================="
	@echo ""
	@echo "Quick Start:"
	@echo "  1. make arch-test-setup    - Install RISCOF (one-time)"
	@echo "  2. make arch-test-rv32i    - Run RV32I tests"
	@echo "  3. make arch-test-report   - View results in browser"
	@echo ""
	@echo "Available Targets:"
	@echo "  arch-test-setup       - Set up RISCOF environment (Python venv + install)"
	@echo "  arch-test-validate    - Validate RISCOF configuration files"
	@echo "  arch-test-rv32i       - Run RV32I base instruction tests"
	@echo "  arch-test-rv32m       - Run RV32M multiply/divide tests"
	@echo "  arch-test-rv32a       - Run RV32A atomic instruction tests"
	@echo "  arch-test-rv32zicsr   - Run Zicsr CSR instruction tests"
	@echo "  arch-test-all         - Run all architectural tests (I+M+A+Zicsr)"
	@echo "  arch-test-sim         - Test kv32sim (DUT) vs spike (REF) - all ISAs (I+M+A+Zicsr+C)"
	@echo "  arch-test-report      - Open test report in browser"
	@echo "  arch-test-clean       - Clean RISCOF work directory"
	@echo "  arch-test-clean-all   - Clean RISCOF work directory and virtual environment"
	@echo ""
	@echo "Trace Comparison (TRACE=1):"
	@echo "  When TRACE=1 is set, each test also runs both kv32soc (RTL) and kv32sim"
	@echo "  with instruction-trace enabled and compares the traces side-by-side."
	@echo "  Example:  make TRACE=1 arch-test-rv32i"
	@echo "  Example:  make TRACE=1 arch-test-sim"
	@echo "  Per-test results: $(RISCOF_WORK)/src/<test>/dut/trace_compare.log"
	@echo ""
	@echo "Test Configurations:"
	@echo "  RTL Tests:        kv32 (Verilator RTL) vs spike (reference)"
	@echo "  Simulator Tests:  kv32sim (C++ sim) vs spike (reference)"
	@echo ""
	@echo "Directories:"
	@echo "  Configuration:   $(RISCOF_DIR)"
	@echo "  Test Suites:     riscv-arch-test/"
	@echo "  Work Directory:  $(RISCOF_WORK)"
	@echo "  Virtual Env:     $(RISCOF_VENV)"
	@echo "  Build Output:    $(BUILD_DIR)"
	@echo ""
	@echo "Example Workflow:"
	@echo "  make arch-test-setup      # One-time setup"
	@echo "  make arch-test-validate   # Verify configuration"
	@echo "  make arch-test-rv32i      # Run base instruction tests"
	@echo "  make arch-test-report     # View HTML report"
	@echo "  make arch-test-all        # Run all tests (takes longer)"
	@echo ""
	@echo "Debug Mode:"
	@echo "  make RISCOF_DEBUG='--verbose info' arch-test-rv32i"
	@echo ""
	@echo "Reports:"
	@echo "  HTML Report:  $(RISCOF_WORK)/report.html"
	@echo "  Test Logs:    $(RISCOF_WORK)/*/DUT-*.log"
	@echo "  Signatures:   $(RISCOF_WORK)/*/DUT-*.signature"
	@echo ""
	@echo "Documentation:"
	@echo "  See $(RISCOF_DIR)/README.md for detailed information"
	@echo "=========================================="
