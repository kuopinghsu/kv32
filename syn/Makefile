# Makefile for rv32 Synthesis and Place & Route
# Uses oss-cad-suite (Yosys + OpenROAD) with ASAP7 7nm PDK

# Force bash shell for consistent behavior
SHELL := /bin/bash

# Include environment configuration
-include ../env.config

# Export environment variables and add tools to PATH
ifdef PATH_APPEND
export PATH := $(PATH_APPEND):$(PATH)
endif

# Tool paths (from PATH)
YOSYS ?= yosys

# Design configuration
DESIGN = rv32
CONFIG = config.tcl

# Directories
SCRIPTS_DIR = scripts
RESULTS_DIR = results
REPORTS_DIR = reports
RTL_DIR = ../rtl

# Scripts
SYNTH_SCRIPT = $(SCRIPTS_DIR)/synthesis.tcl
FORMAL_SCRIPT = $(SCRIPTS_DIR)/formal_equiv.tcl

# Output files
SYNTH_NETLIST = $(RESULTS_DIR)/$(DESIGN)_synth.v
SYNTH_BLIF = $(RESULTS_DIR)/$(DESIGN)_synth.blif
SYNTH_JSON = $(RESULTS_DIR)/$(DESIGN)_synth.json

# Reports
SYNTH_AREA_RPT = $(REPORTS_DIR)/synth_area.rpt
SYNTH_CELLS_RPT = $(REPORTS_DIR)/synth_cells.rpt
SYNTH_TIMING_RPT = $(REPORTS_DIR)/synth_timing_estimate.rpt
FORMAL_RPT = $(REPORTS_DIR)/formal_equiv.rpt

# RTL source files
RTL_SOURCES = \
	$(RTL_DIR)/rv32.sv \
	$(RTL_DIR)/csr.sv \
	$(RTL_DIR)/clint.sv

# Timestamp files for dependency tracking
SYNTH_DONE = $(RESULTS_DIR)/.synth_done

.PHONY: all synth formal clean cleanall check help

# Default target
all: synth

# Check tools availability
check:
	@echo "Checking tool availability..."
	@command -v $(YOSYS) >/dev/null 2>&1 || { echo "ERROR: yosys not found in PATH"; exit 1; }
	@echo "  Yosys: $$($(YOSYS) -V | head -1)"
	@echo ""
	@echo "Checking RTL files..."
	@for file in $(RTL_SOURCES); do \
		if [ ! -f "$$file" ]; then \
			echo "ERROR: RTL file not found: $$file"; \
			exit 1; \
		fi; \
		echo "  Found: $$file"; \
	done
	@echo ""
	@echo "Configuration:"
	@echo "  Design: $(DESIGN)"
	@echo "  Target: ASAP7 7nm PDK @ 120 MHz"
	@echo "  Flow: Synthesis only (Yosys)"
	@echo "  Scripts: $(SCRIPTS_DIR)/"
	@echo "  Results: $(RESULTS_DIR)/"
	@echo "  Reports: $(REPORTS_DIR)/"
	@echo ""
	@echo "All checks passed!"

# Create directories
$(RESULTS_DIR) $(REPORTS_DIR):
	mkdir -p $@

# Synthesis
synth: check $(SYNTH_DONE)

$(SYNTH_DONE): $(RTL_SOURCES) $(CONFIG) $(SYNTH_SCRIPT) | $(RESULTS_DIR) $(REPORTS_DIR)
	@echo "========================================"
	@echo "Running Synthesis"
	@echo "========================================"
	@echo "Design: $(DESIGN)"
	@echo "RTL sources:"
	@for file in $(RTL_SOURCES); do echo "  - $$file"; done
	@echo "Target: ASAP7 7nm @ 120 MHz"
	@echo ""
	@mkdir -p $(REPORTS_DIR)
	$(YOSYS) -c $(SYNTH_SCRIPT)
	@echo ""
	@echo "========================================"
	@echo "Synthesis Summary"
	@echo "========================================"
	@if [ -f $(SYNTH_NETLIST) ]; then \
		echo "✓ Netlist generated: $(SYNTH_NETLIST)"; \
		wc -l $(SYNTH_NETLIST) | awk '{print "  Lines: " $$1}'; \
	else \
		echo "✗ Netlist not generated"; \
		exit 1; \
	fi
	@echo ""
	@echo "Reports:"
	@if [ -f $(SYNTH_AREA_RPT) ]; then \
		echo "  ✓ Area report: $(SYNTH_AREA_RPT)"; \
	fi
	@if [ -f $(SYNTH_CELLS_RPT) ]; then \
		echo "  ✓ Cell usage: $(SYNTH_CELLS_RPT)"; \
	fi
	@if [ -f $(SYNTH_TIMING_RPT) ]; then \
		echo "  ✓ Timing estimate: $(SYNTH_TIMING_RPT)"; \
	fi
	@echo ""
	@echo "Cell Statistics:"
	@grep -A 20 "Number of cells:" $(SYNTH_AREA_RPT) | head -20 || true
	@touch $(SYNTH_DONE)
	@echo ""
	@echo "========================================"
	@echo "Synthesis completed successfully!"
	@echo "========================================"

# View reports
syn-reports: synth
	@echo "========================================"
	@echo "Synthesis Reports"
	@echo "========================================"
	@echo ""
	@if [ -f $(SYNTH_AREA_RPT) ]; then \
		echo "=== AREA REPORT ==="; \
		cat $(SYNTH_AREA_RPT); \
		echo ""; \
	fi
	@if [ -f $(SYNTH_CELLS_RPT) ]; then \
		echo "=== CELL USAGE REPORT ==="; \
		cat $(SYNTH_CELLS_RPT); \
		echo ""; \
	fi
	@if [ -f $(SYNTH_TIMING_RPT) ]; then \
		echo "=== TIMING ESTIMATE REPORT ==="; \
		cat $(SYNTH_TIMING_RPT); \
		echo ""; \
	fi

# View area report only
area: synth
	@if [ -f $(SYNTH_AREA_RPT) ]; then \
		cat $(SYNTH_AREA_RPT); \
	else \
		echo "Area report not found. Run 'make synth' first."; \
	fi

# View cell usage report only
cells: synth
	@if [ -f $(SYNTH_CELLS_RPT) ]; then \
		cat $(SYNTH_CELLS_RPT); \
	else \
		echo "Cell usage report not found. Run 'make synth' first."; \
	fi

# View timing report only
timing: synth
	@if [ -f $(SYNTH_TIMING_RPT) ]; then \
		cat $(SYNTH_TIMING_RPT); \
	else \
		echo "Timing report not found. Run 'make synth' first."; \
	fi

# Formal equivalence checking
formal: synth
	@echo "=========================================="
	@echo "Running Formal Equivalence Check"
	@echo "=========================================="
	@echo "Verifying: RTL <-> Synthesized Netlist"
	@echo ""
	$(YOSYS) -c $(FORMAL_SCRIPT) | tee $(FORMAL_RPT)
	@echo ""
	@if grep -q "Equivalence Check PASSED" $(FORMAL_RPT); then \
		echo "✓ PASSED: Designs are equivalent"; \
		echo "Report: $(FORMAL_RPT)"; \
	else \
		echo "✗ FAILED: Equivalence check failed"; \
		echo "Check: $(FORMAL_RPT)"; \
		exit 1; \
	fi

# View synthesized netlist
view-netlist: synth
	@if [ -f $(SYNTH_NETLIST) ]; then \
		less $(SYNTH_NETLIST); \
	else \
		echo "Netlist not found. Run 'make synth' first."; \
	fi

# Statistics summary
stats: synth
	@echo "========================================"
	@echo "Synthesis Statistics Summary"
	@echo "========================================"
	@echo "Design: $(DESIGN)"
	@echo "Target: 120 MHz (8.33 ns period, ASAP7 7nm)"
	@echo ""
	@if [ -f $(SYNTH_NETLIST) ]; then \
		echo "Netlist:"; \
		wc -l $(SYNTH_NETLIST) | awk '{print "  Lines: " $$1}'; \
		grep -c "wire" $(SYNTH_NETLIST) | awk '{print "  Wires: " $$1}' || echo "  Wires: 0"; \
		grep -c "reg" $(SYNTH_NETLIST) | awk '{print "  Registers: " $$1}' || echo "  Registers: 0"; \
	fi
	@echo ""
	@if [ -f $(SYNTH_AREA_RPT) ]; then \
		echo "Cell Count:"; \
		grep "Number of cells:" $(SYNTH_AREA_RPT) | head -1; \
		grep "AND" $(SYNTH_AREA_RPT) | head -3 || true; \
		grep "DFF" $(SYNTH_AREA_RPT) | head -3 || true; \
	fi
	@echo ""

# Clean build artifacts (keep reports)
clean:
	@echo "Cleaning build artifacts..."
	rm -rf $(RESULTS_DIR)/*
	rm -f $(SYNTH_DONE)
	@echo "Cleaned: $(RESULTS_DIR)/"

# Clean everything including reports
cleanall: clean
	@echo "Cleaning all generated files..."
	rm -rf $(REPORTS_DIR)/*
	@echo "Cleaned: $(REPORTS_DIR)/"

# Help
help:
	@echo "========================================"
	@echo "rv32 Synthesis Makefile"
	@echo "========================================"
	@echo ""
	@echo "Targets:"
	@echo "  make check        - Check tool availability and RTL files"
	@echo "  make synth        - Run synthesis (default)"
	@echo "  make formal       - Run formal equivalence check (RTL vs netlist)"
	@echo "  make reports      - Display all synthesis reports"
	@echo "  make area         - Display area report"
	@echo "  make cells        - Display cell usage report"
	@echo "  make timing       - Display timing estimate"
	@echo "  make stats        - Display statistics summary"
	@echo "  make view-netlist - View synthesized netlist"
	@echo "  make clean        - Remove build artifacts"
	@echo "  make cleanall     - Remove all generated files"
	@echo "  make help         - Display this help"
	@echo ""
	@echo "Configuration:"
	@echo "  Design: $(DESIGN)"
	@echo "  PDK: ASAP7 7nm"
	@echo "  Target Frequency: 120 MHz"
	@echo "  Flow: Synthesis only (no P&R)"
	@echo "  DFT: Disabled"
	@echo ""
	@echo "Tools:"
	@echo "  Yosys: $(YOSYS)"
	@echo ""
	@echo "Environment:"
	@echo "  Ensure Yosys is in PATH (or set PATH_APPEND in ../env.config)"
	@echo ""
	@echo "Quick Start:"
	@echo "  1. make check     # Verify setup"
	@echo "  2. make synth     # Run synthesis"
	@echo "  3. make formal    # Verify equivalence"
	@echo "  4. make reports   # View results"
	@echo ""
