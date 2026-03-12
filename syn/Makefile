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
PDK ?= freepdk45
LIB_ROOT ?= $(CURDIR)/pdk

# OpenRAM memory compiler (set in env.config or override on command line)
OPENRAM ?= /opt/OpenRAM

# Local Python venv for OpenRAM (created by 'make openram-setup', never touches the OpenRAM tree)
VENV_DIR := $(CURDIR)/.venv

# I-cache parameters forwarded to gen-mem (must match syn/common/design.tcl)
ICACHE_SIZE      ?= 4096
ICACHE_LINE_SIZE ?= 32
ICACHE_WAYS      ?= 2

# D-cache parameters forwarded to gen-mem (must match syn/common/design.tcl)
DCACHE_SIZE      ?= 4096
DCACHE_LINE_SIZE ?= 32
DCACHE_WAYS      ?= 2

# Tool binaries (override in env.config if needed)
YOSYS ?= yosys
GENUS ?= genus
DC_SHELL ?= dc_shell

export ACTIVE_CORNER
export PDK
export LIB_ROOT
export OPENRAM

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

.PHONY: all check synth openram-setup gen-mem formal syn-reports area timing cells clean cleanall help

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

openram-setup:
	@echo "======================================="
	@echo "Creating local OpenRAM Python venv"
	@echo "  venv:    $(VENV_DIR)"
	@echo "  OpenRAM: $(OPENRAM)"
	@echo "======================================="
	@if [ ! -d "$(OPENRAM)" ]; then \
	  echo "ERROR: OPENRAM not found at '$(OPENRAM)'"; \
	  exit 1; \
	fi
	@python3 -m venv $(VENV_DIR)
	@$(VENV_DIR)/bin/pip install --upgrade pip --quiet
	@if [ -f "$(OPENRAM)/requirements.txt" ]; then \
	  $(VENV_DIR)/bin/pip install -r $(OPENRAM)/requirements.txt --quiet; \
	else \
	  echo "WARNING: $(OPENRAM)/requirements.txt not found, skipping package install"; \
	fi
	@# Pin numpy<2 and gdspy for OpenRAM 1.x compatibility (numpy 2.0 broke float(array) API)
	@$(VENV_DIR)/bin/pip install "numpy<2" "gdspy" --quiet
	@SITE_PKG=$$($(VENV_DIR)/bin/python3 -c \
	  "import site; print(site.getsitepackages()[0])") && \
	  cp common/openram_sitecustomize.py $$SITE_PKG/sitecustomize.py && \
	  echo "Installed OpenRAM tech patch → $$SITE_PKG/sitecustomize.py"
	@echo "venv ready at $(VENV_DIR)"
	@echo "Activate with: source $(VENV_DIR)/bin/activate"

gen-mem:
	@echo "========================================"
	@echo "Generating OpenRAM SRAM macros"
	@echo "  PDK:              $(PDK)"
	@echo "  OPENRAM:          $(OPENRAM)"
	@echo "  ICACHE_SIZE:      $(ICACHE_SIZE)"
	@echo "  ICACHE_LINE_SIZE: $(ICACHE_LINE_SIZE)"
	@echo "  ICACHE_WAYS:      $(ICACHE_WAYS)"
	@echo "  DCACHE_SIZE:      $(DCACHE_SIZE)"
	@echo "  DCACHE_LINE_SIZE: $(DCACHE_LINE_SIZE)"
	@echo "  DCACHE_WAYS:      $(DCACHE_WAYS)"
	@echo "========================================"
	@if [ ! -d "$(OPENRAM)" ]; then \
	  echo "ERROR: OPENRAM not found at '$(OPENRAM)'"; \
	  echo "Set OPENRAM in env.config or: make gen-mem OPENRAM=/path/to/openram"; \
	  exit 1; \
	fi
	@if [ "$(PDK)" != "freepdk45" ]; then \
	  echo "WARNING: OpenRAM is tested with PDK=freepdk45."; \
	  echo "         PDK=$(PDK) may require a custom technology directory."; \
	fi
	@mkdir -p lib/openram
	@echo "Generating OpenRAM config files..."
	@python3 common/gen_openram_configs.py \
	  --icache-size $(ICACHE_SIZE) \
	  --icache-line-size $(ICACHE_LINE_SIZE) \
	  --icache-ways $(ICACHE_WAYS) \
	  --dcache-size $(DCACHE_SIZE) \
	  --dcache-line-size $(DCACHE_LINE_SIZE) \
	  --dcache-ways $(DCACHE_WAYS) \
	  --pdk $(PDK) \
	  --output-dir lib/openram
	@if [ ! -f "$(VENV_DIR)/bin/activate" ]; then \
	  echo "ERROR: local venv not found at $(VENV_DIR)"; \
	  echo "       Run 'make openram-setup' first."; \
	  exit 1; \
	fi
	@echo "Running OpenRAM for tag SRAM..."
	@cd lib/openram && \
	  . $(VENV_DIR)/bin/activate && \
	  OPENRAM_HOME=$(OPENRAM)/compiler OPENRAM_TECH=$(OPENRAM)/technology \
	  PYTHONPATH=$(OPENRAM)/compiler \
	  python3 $(OPENRAM)/sram_compiler.py openram_tag_sram.py
	@echo "Running OpenRAM for data SRAM..."
	@cd lib/openram && \
	  . $(VENV_DIR)/bin/activate && \
	  OPENRAM_HOME=$(OPENRAM)/compiler OPENRAM_TECH=$(OPENRAM)/technology \
	  PYTHONPATH=$(OPENRAM)/compiler \
	  python3 $(OPENRAM)/sram_compiler.py openram_data_sram.py
	@echo "Running OpenRAM for D-cache tag SRAM..."
	@cd lib/openram && \
	  . $(VENV_DIR)/bin/activate && \
	  OPENRAM_HOME=$(OPENRAM)/compiler OPENRAM_TECH=$(OPENRAM)/technology \
	  PYTHONPATH=$(OPENRAM)/compiler \
	  python3 $(OPENRAM)/sram_compiler.py openram_dcache_tag_sram.py
	@echo "Running OpenRAM for D-cache data SRAM..."
	@cd lib/openram && \
	  . $(VENV_DIR)/bin/activate && \
	  OPENRAM_HOME=$(OPENRAM)/compiler OPENRAM_TECH=$(OPENRAM)/technology \
	  PYTHONPATH=$(OPENRAM)/compiler \
	  python3 $(OPENRAM)/sram_compiler.py openram_dcache_data_sram.py
	@echo "========================================"
	@echo "OpenRAM macros generated in lib/openram/"
	@echo "Run 'make synth' to use the generated macros."
	@echo "========================================"

formal:
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
	@echo "Removing local OpenRAM venv and generated macros..."
	@rm -rf $(VENV_DIR) lib/openram
	@echo "All generated synthesis files removed (build/)."

help:
	@echo "kv32 unified synthesis flow"
	@echo ""
	@echo "Usage:"
	@echo "  make synth                        # default Yosys + FreePDK45"
	@echo "  make synth SYNTH_TOOL=genus       # Cadence Genus"
	@echo "  make synth SYNTH_TOOL=dc          # Synopsys DC"
	@echo "  make synth PDK=asap7              # ASAP7 7nm instead of FreePDK45"
	@echo "  make synth SYNTH_TOOL=yosys ACTIVE_CORNER=tt"
	@echo "  make openram-setup                # Create local Python venv for OpenRAM"
	@echo "  make gen-mem                      # Generate OpenRAM SRAM macros (FreePDK45)"
	@echo "  make gen-mem PDK=asap7            # Generate macros for ASAP7"
	@echo ""
	@echo "Variables:"
	@echo "  SYNTH_TOOL    = yosys | genus | dc"
	@echo "  PDK           = freepdk45 (default) | asap7"
	@echo "  ACTIVE_CORNER = tt | ss | ff"
	@echo "  LIB_ROOT      = pdk (default)"
	@echo "  OPENRAM       = /opt/OpenRAM (default; set in env.config)"
	@echo "  VENV_DIR      = $(VENV_DIR) (local venv, created by openram-setup)"
	@echo "  ICACHE_SIZE / ICACHE_LINE_SIZE / ICACHE_WAYS  (for gen-mem, I-cache)"
	@echo "  DCACHE_SIZE / DCACHE_LINE_SIZE / DCACHE_WAYS  (for gen-mem, D-cache)"
	@echo ""
	@echo "Notes:"
	@echo "  - Use build/reports/<tool>/ and build/results/<tool>/ for outputs"
	@echo "  - 'formal' target is Yosys-only"
