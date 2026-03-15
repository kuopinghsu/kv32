# Zephyr framework build-only targets.

-include ../../env.config

PROJECT_ROOT = $(realpath ../..)
BUILD_DIR    = $(PROJECT_ROOT)/build

RISCV_PREFIX ?= riscv32-unknown-elf-
OBJDUMP      = $(RISCV_PREFIX)objdump
READELF      = $(RISCV_PREFIX)readelf

ZEPHYR_DIR         = $(PROJECT_ROOT)/rtos/zephyr
ZEPHYR_VENV        = $(ZEPHYR_DIR)/.venv
ZEPHYR_SAMPLES     = $(ZEPHYR_DIR)/samples
ZEPHYR_WORKSPACE   = $(abspath $(dir $(ZEPHYR_BASE)))
ZEPHYR_BUILD_ROOT  = $(ZEPHYR_DIR)/build
ZEPHYR_BUILD_DIR   = $(ZEPHYR_BUILD_ROOT).$(TEST)

ZEPHYR_TOOLCHAIN_VARIANT ?= cross-compile
CROSS_COMPILE ?= $(RISCV_PREFIX)

SAMPLE_DIRS  = $(wildcard $(ZEPHYR_SAMPLES)/*)
SAMPLE_NAMES = $(notdir $(SAMPLE_DIRS))

.PHONY: help list-tests setup build clean clean-all

help:
	@echo "Zephyr framework build targets"
	@echo "  make -C rtos/zephyr setup"
	@echo "  make -C rtos/zephyr build TEST=<sample|all>"
	@echo "  make -C rtos/zephyr list-tests"
	@echo "  make -C rtos/zephyr clean"
	@echo "  make -C rtos/zephyr clean-all"
	@echo ""
	@echo "Run through root shared targets:"
	@echo "  make rtl-zephyr-<sample|all>"
	@echo "  make sim-zephyr-<sample|all>"
	@echo "  make spike-zephyr-<sample|all>"
	@echo "  make compare-zephyr-<sample|all>"

list-tests:
	@for t in $(SAMPLE_NAMES); do echo $$t; done

# setup performs the Zephyr prerequisite bootstrap once:
# 1) python venv, 2) west tooling, 3) west export/sanity checks.
setup:
	@if [ -z "$(ZEPHYR_BASE)" ]; then \
		echo "Error: ZEPHYR_BASE is not set"; \
		echo "Set it in env.config (or your shell) to your Zephyr tree path"; \
		exit 1; \
	fi
	@if [ ! -d "$(ZEPHYR_BASE)" ]; then \
		echo "Error: ZEPHYR_BASE directory not found: $(ZEPHYR_BASE)"; \
		exit 1; \
	fi
	@if [ ! -f "$(ZEPHYR_BASE)/zephyr-env.sh" ]; then \
		echo "Error: $(ZEPHYR_BASE) does not look like a Zephyr base directory"; \
		echo "Expected file: $(ZEPHYR_BASE)/zephyr-env.sh"; \
		exit 1; \
	fi
	@if [ ! -d "$(ZEPHYR_VENV)" ]; then \
		echo "Creating Zephyr virtual environment at $(ZEPHYR_VENV)"; \
		python3 -m venv "$(ZEPHYR_VENV)"; \
	fi
	@. "$(ZEPHYR_VENV)/bin/activate" && \
		python3 -m pip install --upgrade pip setuptools wheel && \
		python3 -m pip install --upgrade west cmake ninja jsonschema pyelftools
	@. "$(ZEPHYR_VENV)/bin/activate" && \
		cd "$(ZEPHYR_WORKSPACE)" && \
		west zephyr-export
	@if [ ! -d "$(ZEPHYR_WORKSPACE)/.west" ]; then \
		echo "Warning: west workspace metadata not found at $(ZEPHYR_WORKSPACE)/.west"; \
		echo "If builds fail, initialize/update your Zephyr workspace with west"; \
	fi
	@echo "Zephyr setup complete"

build: setup
	@if [ -z "$(TEST)" ]; then \
		echo "Error: TEST is required"; exit 1; \
	fi
	@if [ "$(TEST)" = "all" ]; then \
		failed=0; \
		for t in $(SAMPLE_NAMES); do \
			if ! $(MAKE) --no-print-directory build TEST=$$t; then failed=1; fi; \
		done; \
		exit $$failed; \
	fi
	@if [ ! -d "$(ZEPHYR_SAMPLES)/$(TEST)" ]; then \
		echo "Error: Zephyr sample '$(TEST)' not found"; \
		exit 1; \
	fi
	@if [ -f "$(ZEPHYR_BASE)/scripts/kconfig/kconfig.py" ] && \
	   ! grep -q "# PATCHED: Skip error on warnings" "$(ZEPHYR_BASE)/scripts/kconfig/kconfig.py"; then \
		echo "Note: applying local kconfig warning patch"; \
		export ZEPHYR_BASE="$(ZEPHYR_BASE)" && bash "$(ZEPHYR_DIR)/patch_kconfig.sh" || \
			(echo "Warning: patch_kconfig.sh failed; continuing"; true); \
	fi
	@mkdir -p "$(BUILD_DIR)"
	@. "$(ZEPHYR_VENV)/bin/activate" && \
		export ZEPHYR_BASE="$(ZEPHYR_BASE)" && \
		export ZEPHYR_TOOLCHAIN_VARIANT="$(ZEPHYR_TOOLCHAIN_VARIANT)" && \
		export CROSS_COMPILE="$(CROSS_COMPILE)" && \
		export ZEPHYR_MODULES="$(ZEPHYR_DIR)" && \
		cd "$(ZEPHYR_WORKSPACE)" && \
		west build -p -b kcore_board -d "$(ZEPHYR_BUILD_DIR)" "$(ZEPHYR_SAMPLES)/$(TEST)" -- \
			-DZEPHYR_BASE="$(ZEPHYR_BASE)" \
			-DZEPHYR_TOOLCHAIN_VARIANT="$(ZEPHYR_TOOLCHAIN_VARIANT)" \
			-DCROSS_COMPILE="$(CROSS_COMPILE)" \
			-DZEPHYR_MODULES="$(ZEPHYR_DIR)" \
			-DKCONFIG_ERROR_ON_WARNINGS=OFF
	@cp "$(ZEPHYR_BUILD_DIR)/zephyr/zephyr.elf" "$(BUILD_DIR)/zephyr-$(TEST).elf"
	@$(OBJDUMP) -D "$(BUILD_DIR)/zephyr-$(TEST).elf" > "$(BUILD_DIR)/zephyr-$(TEST).dis"
	@$(READELF) -a "$(BUILD_DIR)/zephyr-$(TEST).elf" > "$(BUILD_DIR)/zephyr-$(TEST).readelf"

clean:
	@rm -rf "$(ZEPHYR_BUILD_ROOT)".*
	@rm -f "$(BUILD_DIR)/zephyr-"*.elf
	@rm -f "$(BUILD_DIR)/zephyr-"*.dis
	@rm -f "$(BUILD_DIR)/zephyr-"*.readelf

clean-all: clean
	@rm -rf "$(ZEPHYR_VENV)"
