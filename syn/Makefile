# Unified synthesis Makefile for kv32
# Supports Yosys, Cadence Genus, and Synopsys Design Compiler.

SHELL := /bin/bash

-include ../env.config

ifdef PATH_APPEND
export PATH := $(PATH_APPEND):$(PATH)
endif

DESIGN := kv32_soc

# Tool selection
SYNTH_TOOL ?= yosys
ACTIVE_CORNER ?= tt
LIB_ROOT ?= $(CURDIR)/pdk

# Tool binaries (override in env.config if needed)
YOSYS ?= yosys
GENUS ?= genus
DC_SHELL ?= dc_shell

export ACTIVE_CORNER
export LIB_ROOT

RTL_FILELIST := common/rtl_filelist.f

BUILD_DIR := build
RESULTS_DIR := $(BUILD_DIR)/results/$(SYNTH_TOOL)
REPORTS_DIR := $(BUILD_DIR)/reports/$(SYNTH_TOOL)
LOGS_DIR := $(BUILD_DIR)/logs
FV_DIR := $(BUILD_DIR)/fv
SYNTH_DONE := $(BUILD_DIR)/.synth_done_$(SYNTH_TOOL)

YOSYS_SYNTH_SCRIPT := scripts/yosys/synthesis.tcl
YOSYS_FORMAL_SCRIPT := scripts/yosys/formal_equiv.tcl
GENUS_SYNTH_SCRIPT := scripts/genus/synthesis.tcl
DC_SYNTH_SCRIPT := scripts/dc/synthesis.tcl

RTL_SOURCES := $(shell sed '/^$$/d' $(RTL_FILELIST))

.PHONY: all check synth formal syn-reports area timing cells clean cleanall help

all: synth

check:
	@echo "Checking synthesis setup..."
	@case "$(SYNTH_TOOL)" in \
	  yosys) command -v $(YOSYS) >/dev/null 2>&1 || { echo "ERROR: yosys not found"; exit 1; } ;; \
	  genus) command -v $(GENUS) >/dev/null 2>&1 || { echo "ERROR: genus not found"; exit 1; } ;; \
	  dc) command -v $(DC_SHELL) >/dev/null 2>&1 || { echo "ERROR: dc_shell not found"; exit 1; } ;; \
	  *) echo "ERROR: Unsupported SYNTH_TOOL='$(SYNTH_TOOL)' (use yosys|genus|dc)"; exit 1 ;; \
	esac
	@echo "Tool: $(SYNTH_TOOL)"
	@echo "Corner: $(ACTIVE_CORNER)"
	@echo "LIB_ROOT: $(LIB_ROOT)"
	@echo "Checking RTL filelist..."
	@while read -r f; do \
	  [ -z "$$f" ] && continue; \
	  if [ ! -f "$$f" ]; then echo "ERROR: RTL file missing: $$f"; exit 1; fi; \
	  echo "  Found: $$f"; \
	done < $(RTL_FILELIST)
	@echo "Checks passed."

$(BUILD_DIR) $(RESULTS_DIR) $(REPORTS_DIR) $(LOGS_DIR) $(FV_DIR):
	@mkdir -p $@

synth: check $(SYNTH_DONE)

$(SYNTH_DONE): $(RTL_FILELIST) common/design.tcl common/constraints.sdc $(YOSYS_SYNTH_SCRIPT) $(GENUS_SYNTH_SCRIPT) $(DC_SYNTH_SCRIPT) | $(BUILD_DIR) $(RESULTS_DIR) $(REPORTS_DIR) $(LOGS_DIR) $(FV_DIR)
	@echo "========================================"
	@echo "Running synthesis"
	@echo "  Design: $(DESIGN)"
	@echo "  Tool: $(SYNTH_TOOL)"
	@echo "  Corner: $(ACTIVE_CORNER)"
	@echo "========================================"
	@status=0; \
	case "$(SYNTH_TOOL)" in \
	  yosys) (cd $(BUILD_DIR) && $(YOSYS) -c ../$(YOSYS_SYNTH_SCRIPT)) || status=$$? ;; \
	  genus) (cd $(BUILD_DIR) && $(GENUS) -batch -files ../$(GENUS_SYNTH_SCRIPT)) | tee $(LOGS_DIR)/genus_run.log || status=$$? ;; \
	  dc) (cd $(BUILD_DIR) && $(DC_SHELL) -f ../$(DC_SYNTH_SCRIPT)) | tee $(LOGS_DIR)/dc_run.log || status=$$? ;; \
	  *) echo "ERROR: Unsupported SYNTH_TOOL='$(SYNTH_TOOL)'"; exit 1 ;; \
	esac; \
	[ -f $(BUILD_DIR)/genus.log ] && mv -f $(BUILD_DIR)/genus.log $(LOGS_DIR)/genus.log || true; \
	[ -f $(BUILD_DIR)/genus.cmd ] && mv -f $(BUILD_DIR)/genus.cmd $(LOGS_DIR)/genus.cmd || true; \
	if compgen -G "$(BUILD_DIR)/.rs_*.tstamp" > /dev/null; then mv -f $(BUILD_DIR)/.rs_*.tstamp $(LOGS_DIR)/; fi; \
	[ $$status -eq 0 ] || exit $$status
	@case "$(SYNTH_TOOL)" in \
	  yosys) test -f $(BUILD_DIR)/results/yosys/$(DESIGN)_synth.v ;; \
	  genus) test -f $(BUILD_DIR)/results/genus/$(DESIGN)_synth.v ;; \
	  dc) test -f $(BUILD_DIR)/results/dc/$(DESIGN)_synth.v ;; \
	  *) false ;; \
	esac || { echo "ERROR: synthesis output netlist missing for $(SYNTH_TOOL)"; exit 1; }
	@touch $(SYNTH_DONE)
	@echo "Done. Results: $(RESULTS_DIR)  Reports: $(REPORTS_DIR)"

formal:
	@if [ "$(SYNTH_TOOL)" != "yosys" ]; then \
	  echo "Formal target is available only for SYNTH_TOOL=yosys"; \
	  exit 1; \
	fi
	@mkdir -p $(BUILD_DIR)/reports/yosys
	(cd $(BUILD_DIR) && $(YOSYS) -c ../$(YOSYS_FORMAL_SCRIPT)) | tee $(BUILD_DIR)/reports/yosys/formal_equiv.rpt

syn-reports: synth
	@echo "Report files in $(REPORTS_DIR):"
	@ls -1 $(REPORTS_DIR) || true

area: synth
	@ls -1 $(REPORTS_DIR)/*area*.rpt 2>/dev/null | xargs -r -I{} sh -c 'echo "=== {} ==="; cat "{}"; echo'

timing: synth
	@ls -1 $(REPORTS_DIR)/*timing*.rpt 2>/dev/null | xargs -r -I{} sh -c 'echo "=== {} ==="; cat "{}"; echo'

cells: synth
	@ls -1 $(REPORTS_DIR)/*cell*.rpt 2>/dev/null | xargs -r -I{} sh -c 'echo "=== {} ==="; cat "{}"; echo'

clean:
	@echo "Cleaning generated synthesis outputs..."
	@rm -rf $(BUILD_DIR)

cleanall: clean
	@echo "All generated synthesis files removed (build/)."

help:
	@echo "kv32 unified synthesis flow"
	@echo ""
	@echo "Usage:"
	@echo "  make synth                         # default Yosys"
	@echo "  make synth SYNTH_TOOL=genus       # Cadence Genus"
	@echo "  make synth SYNTH_TOOL=dc          # Synopsys DC"
	@echo "  make synth SYNTH_TOOL=yosys ACTIVE_CORNER=tt"
	@echo ""
	@echo "Variables:"
	@echo "  SYNTH_TOOL  = yosys | genus | dc"
	@echo "  ACTIVE_CORNER = tt | ss | ff"
	@echo "  LIB_ROOT = pdk (default)"
	@echo ""
	@echo "Notes:"
	@echo "  - Use build/reports/<tool>/ and build/results/<tool>/ for outputs"
	@echo "  - 'formal' target is Yosys-only"
