# RISC-V SoC Project Makefile
# Main build system for the RV32IMA processor

# On macOS the system make is 3.81 which has jobserver deadlock bugs with nested
# recursive makes.  Prefer gmake (4.x) if available for all $(MAKE) invocations.
MAKE := $(shell command -v gmake 2>/dev/null || command -v make)

# Load environment configuration
-include env.config

# Export environment variables
export RISCV_PREFIX
export VERILATOR
export SPIKE
export SPIKE_INCLUDE
export ZEPHYR_BASE

# Append additional paths if specified
ifdef PATH_APPEND
export PATH := $(PATH):$(PATH_APPEND)
endif

# Project directories
RTL_DIR = rtl
CORE_DIR = $(RTL_DIR)/core
MEM_DIR  = $(RTL_DIR)/memories
TB_DIR = testbench
SIM_DIR = sim
SW_DIR = sw
BUILD_DIR = build

# RISC-V toolchain
RISCV_PREFIX ?= riscv32-unknown-elf-
CC = $(RISCV_PREFIX)gcc
CXX = $(RISCV_PREFIX)g++
OBJDUMP = $(RISCV_PREFIX)objdump
OBJCOPY = $(RISCV_PREFIX)objcopy
READELF = $(RISCV_PREFIX)readelf

MAX_CYCLES ?= 0

# Compiler flags for RV32IMA
CFLAGS = -march=rv32ima_zicsr -mabi=ilp32 -O2 -g
CFLAGS += -Wall -Werror -ffreestanding
CFLAGS += -nostartfiles
CFLAGS += -ffunction-sections -fdata-sections
CFLAGS += -I$(SW_DIR)/common -I$(SW_DIR)/include
CXXFLAGS = $(CFLAGS) -fno-exceptions -fno-rtti -fno-use-cxa-atexit
LDFLAGS = -T$(SW_DIR)/common/link.ld -Wl,--gc-sections
LDFLAGS += -Wl,--wrap=fflush
LDFLAGS += -lc -lgcc -lm
COMMON_SRCS = $(SW_DIR)/common/start.S $(SW_DIR)/common/syscall.c $(SW_DIR)/common/trap.c \
              $(SW_DIR)/common/kv_irq.c \
              $(SW_DIR)/common/puts.c $(SW_DIR)/common/putc.c

# Optional per-test software makefile include.
# Loaded only in recursive software build invocations that set TEST=<name>.
ifneq ($(strip $(TEST)),)
ifneq ($(wildcard $(SW_DIR)/$(TEST)/makefile.mak),)
include $(SW_DIR)/$(TEST)/makefile.mak
endif
endif

# Find all test directories (exclude common and include, only directories with C files)
TEST_DIRS = $(shell find $(SW_DIR) -mindepth 1 -maxdepth 1 -type d ! -name common ! -name include)
TEST_NAMES = $(notdir $(TEST_DIRS))

# Tests to compare (exclude I/O-dependent tests that require external peripherals)
COMPARE_EXCLUDE = full i2c uart spi dma gpio timer
COMPARE_TESTS   = $(filter-out $(COMPARE_EXCLUDE), $(TEST_NAMES))

# Tests to run under Spike (excludes tests not supported by Spike; override with SPIKE_TESTS=<list>)
SPIKE_EXCLUDE = icache
SPIKE_TESTS  ?= $(filter-out $(SPIKE_EXCLUDE), $(TEST_NAMES))

# Software simulator selection (kv32sim or spike)
SIM ?= kv32sim

# Spike MMIO plugin support
SPIKE_DIR     = spike
# CLINT (0x02000000) and PLIC (0x0C000000) are handled by Spike's built-in
# implementations (which match KV32's memory map).  Only load plugins for the
# KV32-specific peripherals that Spike has no built-in knowledge of.
SPIKE_PLUGINS = \
	$(BUILD_DIR)/spike_plugin_magic.so  \
	$(BUILD_DIR)/spike_plugin_uart.so   \
	$(BUILD_DIR)/spike_plugin_i2c.so    \
	$(BUILD_DIR)/spike_plugin_spi.so    \
	$(BUILD_DIR)/spike_plugin_dma.so    \
	$(BUILD_DIR)/spike_plugin_gpio.so   \
	$(BUILD_DIR)/spike_plugin_timer.so

SPIKE_EXTLIBS  = $(patsubst %,--extlib=%,$(SPIKE_PLUGINS))
SPIKE_DEVICES  = \
	-m2047 \
	--device=plugin_magic,0xFFFF0000    \
	--device=plugin_uart,0x20000000     \
	--device=plugin_i2c,0x20010000      \
	--device=plugin_spi,0x20020000      \
	--device=plugin_dma,0x20030000      \
	--device=plugin_gpio,0x20040000     \
	--device=plugin_timer,0x20050000

# Verilator settings
VERILATOR ?= verilator
VERILATOR_JOBS ?= 0
VERILATOR_FLAGS = -Wall -Wno-fatal -Wno-UNSIGNED --trace --trace-fst --cc --exe --build -j $(VERILATOR_JOBS)
VERILATOR_FLAGS += -sv --timing
VERILATOR_FLAGS += --top-module tb_kv32_soc
VERILATOR_FLAGS += -Wno-UNDRIVEN -Wno-UNUSEDPARAM
VERILATOR_FLAGS += -I$(MEM_DIR)

# Assertion control (ASSERT=1 enables, ASSERT=0 disables)
ifndef ASSERT
  ASSERT = 1
endif

ifeq ($(ASSERT),0)
  VERILATOR_FLAGS += +define+NO_ASSERTION
else
  VERILATOR_FLAGS += --assert
endif

# Debug level (DEBUG=1 or DEBUG=2)
ifdef DEBUG
  ifeq ($(DEBUG),1)
    VERILATOR_FLAGS += +define+DEBUG 
    VERILATOR_FLAGS += +define+DEBUG_LEVEL_1
    VERILATOR_FLAGS += -CFLAGS "-DDEBUG=1"
  else ifeq ($(DEBUG),2)
    VERILATOR_FLAGS += +define+DEBUG 
    VERILATOR_FLAGS += +define+DEBUG_LEVEL_1
    VERILATOR_FLAGS += +define+DEBUG_LEVEL_2
    VERILATOR_FLAGS += -CFLAGS "-DDEBUG=2"
  endif
endif

# Coverage collection (COVERAGE=1 enables)
ifeq ($(COVERAGE),1)
  VERILATOR_FLAGS += --coverage --coverage-line --coverage-toggle
endif

# Multiply mode: FAST_MUL=0 selects serial multiplier, default=1 (combinatorial)
ifdef FAST_MUL
  VERILATOR_FLAGS += -pvalue+FAST_MUL=$(FAST_MUL)
endif

# Division mode: FAST_DIV=0 selects serial divider (33 cycles), default=1 (combinatorial)
ifdef FAST_DIV
  VERILATOR_FLAGS += -pvalue+FAST_DIV=$(FAST_DIV)
endif

# External memory latency and port parameters
MEM_READ_LATENCY  ?= 1
MEM_WRITE_LATENCY ?= 1
MEM_DUAL_PORT     ?= 1
VERILATOR_FLAGS += -pvalue+MEM_READ_LATENCY=$(MEM_READ_LATENCY)
VERILATOR_FLAGS += -pvalue+MEM_WRITE_LATENCY=$(MEM_WRITE_LATENCY)
VERILATOR_FLAGS += -pvalue+MEM_DUAL_PORT=$(MEM_DUAL_PORT)

# I-cache defaults (set before ifdef blocks so ?= assignments take effect)
ICACHE_EN    ?= 1
ICACHE_SIZE  ?= 4096
ICACHE_LINE_SIZE ?= 32
ICACHE_WAYS  ?= 2

# I-cache: ICACHE_EN=0 disables the cache (uses mem_axi_ro bypass), default=1
ifdef ICACHE_EN
  VERILATOR_FLAGS += -pvalue+ICACHE_EN=$(ICACHE_EN)
endif
ifdef ICACHE_SIZE
  VERILATOR_FLAGS += -pvalue+ICACHE_SIZE=$(ICACHE_SIZE)
endif
ifdef ICACHE_LINE_SIZE
  VERILATOR_FLAGS += -pvalue+ICACHE_LINE_SIZE=$(ICACHE_LINE_SIZE)
endif
ifdef ICACHE_WAYS
  VERILATOR_FLAGS += -pvalue+ICACHE_WAYS=$(ICACHE_WAYS)
endif

# Stamp file to detect compile-time parameter changes and force rebuild of kv32soc.
# Each variable that is passed to Verilator at elaboration time must be listed here.
# When any value differs from the previous build the stamp file is updated, which
# makes kv32soc appear out-of-date and triggers a fresh Verilator elaboration.
FAST_MUL     ?= 1
FAST_DIV     ?= 1
COVERAGE     ?= 0
DEBUG        ?=
# Pass I-cache parameters to C++ testbench for stats reporting
VERILATOR_FLAGS += -CFLAGS "-DICACHE_EN=$(ICACHE_EN) -DICACHE_SIZE=$(ICACHE_SIZE) -DICACHE_LINE_SIZE=$(ICACHE_LINE_SIZE) -DICACHE_WAYS=$(ICACHE_WAYS)"
RTL_BUILD_PARAMS = FAST_MUL=$(FAST_MUL) FAST_DIV=$(FAST_DIV) ICACHE_EN=$(ICACHE_EN) ICACHE_SIZE=$(ICACHE_SIZE) ICACHE_LINE_SIZE=$(ICACHE_LINE_SIZE) ICACHE_WAYS=$(ICACHE_WAYS) ASSERT=$(ASSERT) DEBUG=$(DEBUG) COVERAGE=$(COVERAGE) MEM_READ_LATENCY=$(MEM_READ_LATENCY) MEM_WRITE_LATENCY=$(MEM_WRITE_LATENCY) MEM_DUAL_PORT=$(MEM_DUAL_PORT)
RTL_PARAMS_STAMP = $(BUILD_DIR)/.build_params

# RTL source files
# Package files must be compiled first
RTL_SOURCES = \
	$(CORE_DIR)/kv32_pkg.sv \
	$(RTL_DIR)/axi_pkg.sv \
	$(filter-out $(CORE_DIR)/kv32_pkg.sv, $(wildcard $(CORE_DIR)/*.sv)) \
	$(filter-out $(RTL_DIR)/axi_pkg.sv, $(wildcard $(RTL_DIR)/*.sv)) \
	$(filter-out $(RTL_DIR)/jtag/PINMUX_EXAMPLES.sv, $(wildcard $(RTL_DIR)/jtag/*.sv)) \
	$(wildcard $(MEM_DIR)/*.sv) \
	$(TB_DIR)/axi_memory.sv \
	$(TB_DIR)/axi_monitor.sv \
	$(TB_DIR)/uart_loopback.sv \
	$(TB_DIR)/spi_slave_memory.sv \
	$(TB_DIR)/i2c_slave_eeprom.sv \
	$(TB_DIR)/tb_kv32_soc.sv

# Testbench source
TB_SOURCES = $(TB_DIR)/tb_kv32_soc.cpp $(TB_DIR)/elfloader.cpp $(SIM_DIR)/riscv-dis.cpp

# Output executable
BUILD_TARGET = $(BUILD_DIR)/kv32soc

.PHONY: all build-rtl build-sim rtl-build sim-build build-spike-plugins clean clean-tests clean-spike-plugins run waves help info rtl-% sim-% spike-% compare-% coverage-% arch-test-% freertos-% rtl-all sim-all spike-all compare-all coverage-all coverage-report __build-test $(TEST_NAMES) FORCE

# Default target - run all tests
all: rtl-all sim-all compare-all spike-all freertos-compare-simple
	@make -f Makefile TRACE=1 arch-test-all
	@make -f Makefile TRACE=1 arch-test-sim

# Verify memory interface
verify-mem:
	@make -f Makefile MEM_READ_LATENCY=1 MEM_WRITE_LATENCY=1 MEM_DUAL_PORT=1 compare-all rtl-all
	@make -f Makefile MEM_READ_LATENCY=4 MEM_WRITE_LATENCY=1 MEM_DUAL_PORT=1 compare-all rtl-all
	@make -f Makefile MEM_READ_LATENCY=1 MEM_WRITE_LATENCY=4 MEM_DUAL_PORT=1 compare-all rtl-all
	@make -f Makefile MEM_READ_LATENCY=16 MEM_WRITE_LATENCY=1 MEM_DUAL_PORT=1 compare-all rtl-all
	@make -f Makefile MEM_READ_LATENCY=1 MEM_WRITE_LATENCY=16 MEM_DUAL_PORT=1 compare-all rtl-all
	@make -f Makefile MEM_READ_LATENCY=1 MEM_WRITE_LATENCY=1 MEM_DUAL_PORT=0 compare-all rtl-all
	@make -f Makefile MEM_READ_LATENCY=4 MEM_WRITE_LATENCY=1 MEM_DUAL_PORT=0 compare-all rtl-all
	@make -f Makefile MEM_READ_LATENCY=1 MEM_WRITE_LATENCY=4 MEM_DUAL_PORT=0 compare-all rtl-all
	@make -f Makefile MEM_READ_LATENCY=16 MEM_WRITE_LATENCY=1 MEM_DUAL_PORT=0 compare-all rtl-all
	@make -f Makefile MEM_READ_LATENCY=1 MEM_WRITE_LATENCY=16 MEM_DUAL_PORT=0 compare-all rtl-all

# Build RTL with Verilator
build-rtl: $(BUILD_TARGET)

# Alias for build-rtl (so both 'make build-rtl' and 'make rtl-build' work)
rtl-build: build-rtl

# Stamp rule: always runs (FORCE), but only touches the file when params changed.
# This means kv32soc is rebuilt only when a compile-time parameter actually differs.
$(RTL_PARAMS_STAMP): FORCE
	@mkdir -p $(BUILD_DIR)
	@printf '%s' "$(RTL_BUILD_PARAMS)" | cmp -s - $@ || printf '%s' "$(RTL_BUILD_PARAMS)" > $@

FORCE:

$(BUILD_TARGET): $(RTL_SOURCES) $(TB_SOURCES) $(RTL_PARAMS_STAMP)
	@echo "=========================================="
	@echo "Building RISC-V SoC with Verilator"
	@echo "=========================================="
	@echo "Verilator: $(VERILATOR)"
	@echo "Build dir: $(BUILD_DIR)"
	@echo "Output:    $(BUILD_TARGET)"
	@echo ""
	@mkdir -p $(BUILD_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		-Mdir $(BUILD_DIR)/objdir \
		-o ../kv32soc \
		-I$(CORE_DIR) \
		-I$(RTL_DIR) \
		$(RTL_SOURCES) \
		$(TB_SOURCES)
	@echo ""
	@echo "=========================================="
	@echo "Build complete!"
	@echo "Simulator: $(BUILD_TARGET)"
	@echo "=========================================="

# Build software simulator (kv32sim)
build-sim:
	@echo "=========================================="
	@echo "Building Software Simulator (kv32sim)"
	@echo "=========================================="
	@$(MAKE) -C $(SIM_DIR) all
	@echo "=========================================="

# Alias for build-sim (so both 'make build-sim' and 'make sim-build' work)
sim-build: build-sim

# Software test program build rules
#
# Use secondary expansion so the stem $* (test name) can be referenced inside
# the prerequisite list.  This lets each %.elf track its own per-test sources
# (sw/<test>/*.c, *.cpp, *.h) so that touching those files triggers a rebuild.
.SECONDEXPANSION:

# Pattern rule to build a test program (handles both C and C++ automatically)
$(BUILD_DIR)/%.elf: $(COMMON_SRCS) $(SW_DIR)/common/link.ld \
                    $$(wildcard $(SW_DIR)/$$*/*.c $(SW_DIR)/$$*/*.cpp $(SW_DIR)/$$*/*.h $(SW_DIR)/$$*/*.S)
	@$(MAKE) --no-print-directory __build-test TEST=$* OUT=$@ DIS_OUT=$(BUILD_DIR)/$*.dis READELF_OUT=$(BUILD_DIR)/$*.readelf

# Pattern rule to build a test program for Spike (with HTIF support)
$(BUILD_DIR)/%-spike.elf: $(COMMON_SRCS) $(SW_DIR)/common/link.ld \
                          $$(wildcard $(SW_DIR)/$$*/*.c $(SW_DIR)/$$*/*.cpp $(SW_DIR)/$$*/*.h $(SW_DIR)/$$*/*.S)
	@$(MAKE) --no-print-directory __build-test TEST=$* OUT=$@ HTIF=1 DIS_OUT=$(BUILD_DIR)/$*-spike.dis READELF_OUT=$(BUILD_DIR)/$*-spike.readelf

# Internal helper target used by software build pattern rules.
__build-test:
	@echo "=========================================="
	@if [ "$(HTIF)" = "1" ]; then \
		echo "Building test for Spike: $(TEST)"; \
	else \
		echo "Building test: $(TEST)"; \
	fi
	@echo "=========================================="
	@mkdir -p $(BUILD_DIR)
	@if [ ! -d "$(SW_DIR)/$(TEST)" ]; then \
		echo "Error: Test directory $(SW_DIR)/$(TEST) not found"; \
		exit 1; \
	fi
	@if [ -f "$(SW_DIR)/$(TEST)/makefile.mak" ]; then \
		echo "Including per-test makefile: $(SW_DIR)/$(TEST)/makefile.mak"; \
	fi
	@# Check for C++ files first (if present, use C++ compiler)
	@if [ -n "$$(find $(SW_DIR)/$(TEST) -maxdepth 1 -name '*.cpp' 2>/dev/null)" ]; then \
		echo "Detected C++ source files, using g++"; \
		$(CXX) $(CXXFLAGS) $(if $(filter 1,$(HTIF)),-DUSE_HTIF) \
			$(COMMON_SRCS) \
			$$(find $(SW_DIR)/$(TEST) -maxdepth 1 -name '*.cpp') \
			$(LDFLAGS) \
			-o $(OUT); \
	elif [ -n "$$(find $(SW_DIR)/$(TEST) -maxdepth 1 -name '*.c' 2>/dev/null)" ]; then \
		echo "Detected C source files, using gcc"; \
		$(CC) $(CFLAGS) $(if $(filter 1,$(HTIF)),-DUSE_HTIF) \
			$(COMMON_SRCS) \
			$$(find $(SW_DIR)/$(TEST) -maxdepth 1 -name '*.c') \
			$(LDFLAGS) \
			-o $(OUT); \
	else \
		echo "Error: No source files (.c or .cpp) found in $(SW_DIR)/$(TEST)"; \
		exit 1; \
	fi
	@echo "Generating disassembly..."
	@$(OBJDUMP) -d $(OUT) > $(DIS_OUT)
	@echo "Generating readelf info..."
	@$(READELF) -a $(OUT) > $(READELF_OUT)
	@echo "Build complete: $(OUT)"
	@echo ""

# Target to build a specific test (e.g., make hello)
$(TEST_NAMES): %:
	@$(MAKE) $(BUILD_DIR)/$*.elf

# Target to run test with RTL simulator (e.g., make rtl-hello)
# Use TRACE=1 to enable instruction trace, WAVE=[1|fst|vcd] for waveform, DEBUG=1 or DEBUG=2 for debug messages
rtl-%:
ifdef DEBUG
	@echo "=========================================="
	@echo "DEBUG=$(DEBUG) specified - rebuilding RTL"
	@echo "=========================================="
	@$(MAKE) clean
	@$(MAKE) build-rtl DEBUG=$(DEBUG)
else
	@$(MAKE) build-rtl
endif
	@$(MAKE) $(BUILD_DIR)/$*.elf
	@echo "=========================================="
	@echo "Running test '$*' with RTL simulator"
ifdef DEBUG
	@echo "Debug level: $(DEBUG)"
endif
	@echo "=========================================="
	@cd $(BUILD_DIR) && ./kv32soc \
		$(if $(TRACE),--trace) \
		$(if $(filter 1 fst,$(WAVE)),--wave=fst) \
		$(if $(filter vcd,$(WAVE)),--wave=vcd) \
		$(if $(filter-out 0,$(MAX_CYCLES)),--instructions=$(MAX_CYCLES)) \
		$*.elf
	@echo ""
	@if [ "$(TRACE)" = "1" ]; then \
		echo "Trace saved to: $(BUILD_DIR)/rtl_trace.txt"; \
	fi
	@if [ "$(WAVE)" = "1" ] || [ "$(WAVE)" = "fst" ]; then \
		echo "Waveform saved to: $(BUILD_DIR)/kv32soc.fst"; \
	elif [ "$(WAVE)" = "vcd" ]; then \
		echo "Waveform saved to: $(BUILD_DIR)/kv32soc.vcd"; \
	fi
	@if [ "$(TRACE)" != "1" ] && [ "$(WAVE)" = "" ]; then \
		echo "Use TRACE=1 for instruction trace, WAVE=fst or WAVE=vcd for waveform dump"; \
	fi
	@echo "=========================================="

# Target to run test with software simulator (e.g., make sim-hello)
# Use TRACE=1 to enable instruction trace
# Use SIM=spike to use Spike instead of kv32sim (default)
# When SIM=spike, builds the Spike MMIO plugins and runs with --extlib + --device.
SPIKE_EXTLIBS_LOCAL = $(patsubst $(BUILD_DIR)/%,--extlib=./%,$(SPIKE_PLUGINS))

ifeq ($(SIM),spike)
_SIM_PREREQ = build-spike-plugins
define _SIM_RUN
cd $(BUILD_DIR) && $(SPIKE) --isa=rv32ima_zicsr_zicntr $(SPIKE_EXTLIBS_LOCAL) $(SPIKE_DEVICES) $(if $(filter 1,$(TRACE)),--log-commits --log=sim_trace.txt) $(1).elf 2>&1 || true
endef
else
_SIM_PREREQ =
define _SIM_RUN
cd $(BUILD_DIR) && ./$(SIM) $(if $(filter 1,$(TRACE)),--rtl-trace --log=sim_trace.txt) $(1).elf
endef
endif

sim-%: build-sim $(_SIM_PREREQ)
	@$(MAKE) $(BUILD_DIR)/$*.elf
	@echo "=========================================="
	@echo "Running test '$*' with software simulator ($(SIM))"
	@echo "=========================================="
	$(call _SIM_RUN,$*)
	@echo ""
ifeq ($(TRACE),1)
	@echo "Trace saved to: $(BUILD_DIR)/sim_trace.txt"
else
	@echo "Use TRACE=1 to enable instruction trace"
endif
	@echo "=========================================="

# Target to run test with Spike simulator (e.g., make spike-hello)
# Always uses Spike regardless of the SIM variable.
# Use TRACE=1 to enable instruction trace.
spike-%: build-spike-plugins
	@$(MAKE) $(BUILD_DIR)/$*.elf
	@echo "=========================================="
	@echo "Running test '$*' with Spike"
	@echo "=========================================="
	cd $(BUILD_DIR) && $(SPIKE) --isa=rv32ima_zicsr_zicntr $(SPIKE_EXTLIBS_LOCAL) $(SPIKE_DEVICES) $(if $(filter 1,$(TRACE)),--log-commits --log=sim_trace.txt) $*.elf 2>&1
	@echo ""
ifeq ($(TRACE),1)
	@echo "Trace saved to: $(BUILD_DIR)/sim_trace.txt"
else
	@echo "Use TRACE=1 to enable instruction trace"
endif
	@echo "=========================================="

# Build all Spike MMIO plugins
build-spike-plugins:
	@echo "=========================================="
	@echo "Building Spike MMIO plugins"
	@echo "=========================================="
	@$(MAKE) -C $(SPIKE_DIR) BUILD_DIR=../$(BUILD_DIR) SPIKE_INCLUDE=$(SPIKE_INCLUDE)
	@echo ""

# Target to compare RTL and software simulator traces (e.g., make compare-hello)
# Runs both RTL and sim with TRACE=1 and compares the traces
compare-%:
	@echo "=========================================="
	@echo "Comparing test '$*': RTL vs Software Simulator"
	@echo "=========================================="
	@if echo " $(COMPARE_EXCLUDE) " | grep -q " $* "; then \
		echo "WARNING: '$*' is in COMPARE_EXCLUDE and is not expected to produce"; \
		echo "         a matching trace. Possible reasons:"; \
		echo "          - I/O-dependent test (uart, i2c, spi, dma, gpio, timer)"; \
		echo "          - Other architectural differences"; \
		echo ""; \
		echo "         Proceeding anyway — mismatch is expected."; \
		echo "=========================================="; \
	fi
	@echo "Step 1: Running RTL simulator with trace..."
	@-$(MAKE) rtl-$* TRACE=1
	@echo ""
	@echo "Step 2: Running software simulator with trace..."
	@-$(MAKE) sim-$* TRACE=1
	@echo ""
	@echo "Step 3: Comparing traces..."
	@echo "=========================================="
	@if [ ! -f scripts/trace_compare.py ]; then \
		echo "Error: scripts/trace_compare.py not found"; \
		exit 1; \
	fi
	@if [ ! -f $(BUILD_DIR)/rtl_trace.txt ]; then \
		echo "Error: $(BUILD_DIR)/rtl_trace.txt not found"; \
		exit 1; \
	fi
	@if [ ! -f $(BUILD_DIR)/sim_trace.txt ]; then \
		echo "Error: $(BUILD_DIR)/sim_trace.txt not found"; \
		exit 1; \
	fi
	@python3 scripts/trace_compare.py $(BUILD_DIR)/sim_trace.txt $(BUILD_DIR)/rtl_trace.txt
	@echo "=========================================="
	@echo "Trace comparison complete!"
	@echo "=========================================="

# Target to run test with coverage collection (e.g., make coverage-hello)
# Builds RTL with coverage enabled and runs test
coverage-%:
	@echo "=========================================="
	@echo "Running test '$*' with coverage collection"
	@echo "=========================================="
	@echo "Step 1: Building RTL with coverage enabled..."
	@$(MAKE) clean > /dev/null 2>&1
	@$(MAKE) build-rtl COVERAGE=1 > /dev/null 2>&1
	@echo "Step 2: Running test..."
	@$(MAKE) -s rtl-$*
	@echo ""
	@echo "Coverage data saved to: $(BUILD_DIR)/objdir/coverage.dat"
	@echo "To generate report: make coverage-report"
	@echo "=========================================="
	@echo "Trace comparison complete!"
	@echo "=========================================="

# Target to run all RTL tests
rtl-all:
ifdef DEBUG
	@echo "=========================================="
	@echo "DEBUG=$(DEBUG) specified - rebuilding RTL"
	@echo "=========================================="
	@$(MAKE) clean
	@$(MAKE) build-rtl DEBUG=$(DEBUG)
else
	@$(MAKE) build-rtl
endif
	@echo "=========================================="
	@echo "Running all RTL tests"
	@echo "=========================================="
	@echo "Tests to run: $(TEST_NAMES)"
	@echo ""
	@passed=0; failed=0; \
	for test in $(TEST_NAMES); do \
		echo "==========================================";\
		echo "Running RTL test: $$test";\
		echo "==========================================";\
		if $(MAKE) -s $(BUILD_DIR)/$$test.elf && \
		   (cd $(BUILD_DIR) && ./kv32soc \
			$(if $(TRACE),--trace) \
			$(if $(filter 1 fst,$(WAVE)),--wave=fst) \
			$(if $(filter vcd,$(WAVE)),--wave=vcd) \
			$(if $(filter-out 0,$(MAX_CYCLES)),--instructions=$(MAX_CYCLES)) \
			$$test.elf); then \
			echo "✓ $$test PASSED"; \
			passed=$$((passed + 1)); \
		else \
			echo "✗ $$test FAILED"; \
			failed=$$((failed + 1)); \
		fi; \
		echo ""; \
	done; \
	echo "==========================================";\
	echo "RTL Test Summary";\
	echo "==========================================";\
	echo "Total:  $$((passed + failed))";\
	echo "Passed: $$passed";\
	echo "Failed: $$failed";\
	echo "==========================================";\
	if [ $$failed -gt 0 ]; then exit 1; fi

# Target to run all software simulator tests
sim-all: build-sim $(_SIM_PREREQ)
	@echo "=========================================="
	@echo "Running all software simulator tests ($(SIM))"
	@echo "=========================================="
	@echo "Tests to run: $(TEST_NAMES)"
	@echo ""
	@passed=0; failed=0; \
	for test in $(TEST_NAMES); do \
		if $(MAKE) -s _SIM_PREREQ= sim-$$test; then \
			echo "✓ $$test PASSED"; \
			passed=$$((passed + 1)); \
		else \
			echo "✗ $$test FAILED"; \
			failed=$$((failed + 1)); \
		fi; \
		echo ""; \
	done; \
	echo "==========================================";\
	echo "Simulator Test Summary";\
	echo "==========================================";\
	echo "Total:  $$((passed + failed))";\
	echo "Passed: $$passed";\
	echo "Failed: $$failed";\
	echo "==========================================";\
	if [ $$failed -gt 0 ]; then exit 1; fi

# Target to run all tests under Spike with MMIO plugins (e.g., make spike-all)
# Override the test list with: make spike-all SPIKE_TESTS="hello simple uart"
spike-all: build-spike-plugins
	@echo "=========================================="
	@echo "Running Spike tests: $(SPIKE_TESTS)"
	@echo "=========================================="
	@echo ""
	@passed=0; failed=0; \
	for test in $(SPIKE_TESTS); do \
		if $(MAKE) -s spike-$$test; then \
			echo "✓ $$test PASSED"; \
			passed=$$((passed + 1)); \
		else \
			echo "✗ $$test FAILED"; \
			failed=$$((failed + 1)); \
		fi; \
		echo ""; \
	done; \
	echo "==========================================";\
	echo "Spike Test Summary";\
	echo "==========================================";\
	echo "Total:  $$((passed + failed))";\
	echo "Passed: $$passed";\
	echo "Failed: $$failed";\
	echo "==========================================";\
	if [ $$failed -gt 0 ]; then exit 1; fi

# Target to compare all tests (RTL vs software simulator traces)
compare-all:
	@echo "=========================================="
	@echo "Comparing all tests: RTL vs Software Simulator"
	@echo "=========================================="
	@echo "Tests to compare: $(COMPARE_TESTS)"
	@echo "Excluded (I/O): $(COMPARE_EXCLUDE)"
	@echo ""
	@if [ ! -f scripts/trace_compare.py ]; then \
		echo "Error: scripts/trace_compare.py not found"; \
		exit 1; \
	fi
	@passed=0; failed=0; \
	for test in $(COMPARE_TESTS); do \
		echo "==========================================";\
		echo "Comparing test: $$test";\
		echo "==========================================";\
		echo "Step 1: Running RTL simulator with trace...";\
		if $(MAKE) -s rtl-$$test TRACE=1 > /tmp/rtl_$$test.log 2>&1; then \
			echo "  RTL completed"; \
		else \
			echo "✗ $$test RTL FAILED (exit code $$?)"; \
			echo "  See /tmp/rtl_$$test.log for details"; \
			tail -20 /tmp/rtl_$$test.log | sed 's/^/  /'; \
			failed=$$((failed + 1)); \
			echo ""; \
			continue; \
		fi; \
		echo "Step 2: Running software simulator with trace..."; \
		if $(MAKE) -s sim-$$test TRACE=1 > /tmp/sim_$$test.log 2>&1; then \
			echo "  SIM completed"; \
		else \
			echo "✗ $$test SIM FAILED (exit code $$?)"; \
			echo "  See /tmp/sim_$$test.log for details"; \
			tail -20 /tmp/sim_$$test.log | sed 's/^/  /'; \
			failed=$$((failed + 1)); \
			echo ""; \
			continue; \
		fi; \
		echo "Step 3: Comparing traces..."; \
		if [ ! -f $(BUILD_DIR)/rtl_trace.txt ]; then \
			echo "✗ $$test - RTL trace not found"; \
			failed=$$((failed + 1)); \
		elif [ ! -f $(BUILD_DIR)/sim_trace.txt ]; then \
			echo "✗ $$test - SIM trace not found"; \
			failed=$$((failed + 1)); \
		elif python3 scripts/trace_compare.py $(BUILD_DIR)/sim_trace.txt $(BUILD_DIR)/rtl_trace.txt > /tmp/cmp_$$test.log 2>&1; then \
			echo "✓ $$test TRACES MATCH"; \
			passed=$$((passed + 1)); \
		else \
			echo "✗ $$test TRACES DIFFER"; \
			echo "  Comparison output:"; \
			tail -10 /tmp/cmp_$$test.log | sed 's/^/  /'; \
			failed=$$((failed + 1)); \
		fi; \
		echo ""; \
	done; \
	echo "==========================================";\
	echo "Comparison Summary";\
	echo "==========================================";\
	echo "Total:  $$((passed + failed))";\
	echo "Passed: $$passed";\
	echo "Failed: $$failed";\
	echo "==========================================";\
	if [ $$failed -gt 0 ]; then exit 1; fi

# Target to collect coverage from all tests
coverage-all:
	@echo "=========================================="
	@echo "Running all tests with coverage collection"
	@echo "=========================================="
	@echo "Tests to run: $(TEST_NAMES)"
	@echo ""
	@echo "Step 1: Building RTL with coverage enabled..."
	@$(MAKE) clean > /dev/null 2>&1
	@$(MAKE) build-rtl COVERAGE=1 > /dev/null 2>&1
	@echo "Step 2: Running tests..."
	@echo ""
	@passed=0; failed=0; \
	for test in $(TEST_NAMES); do \
		echo "Running: $$test"; \
		if $(MAKE) -s $(BUILD_DIR)/$$test.elf > /dev/null 2>&1 && \
		   (cd $(BUILD_DIR) && ./kv32soc \
			$(if $(filter-out 0,$(MAX_CYCLES)),--instructions=$(MAX_CYCLES)) \
			$$test.elf > /dev/null 2>&1); then \
			echo "✓ $$test completed"; \
			passed=$$((passed + 1)); \
		else \
			echo "✗ $$test failed"; \
			failed=$$((failed + 1)); \
		fi; \
	done; \
	echo ""; \
	echo "=========================================="; \
	echo "Coverage Collection Summary"; \
	echo "=========================================="; \
	echo "Total:  $$((passed + failed))"; \
	echo "Passed: $$passed"; \
	echo "Failed: $$failed"; \
	echo "=========================================="; \
	echo ""; \
	echo "Generating coverage report..."; \
	$(MAKE) coverage-report

# Generate coverage report from collected data
coverage-report:
	@echo "=========================================="
	@echo "Generating Verilator Coverage Report"
	@echo "=========================================="
	@if [ ! -f $(BUILD_DIR)/objdir/coverage.dat ]; then \
		echo "Error: No coverage data found at $(BUILD_DIR)/objdir/coverage.dat"; \
		echo "Run 'make coverage-<test>' or 'make coverage-all' first"; \
		exit 1; \
	fi
	@echo "Coverage data: $(BUILD_DIR)/objdir/coverage.dat"
	@echo ""
	@echo "Step 1: Generating info file..."
	@verilator_coverage --write-info $(BUILD_DIR)/coverage.info $(BUILD_DIR)/objdir/coverage.dat
	@echo "Step 2: Generating HTML report with lcov..."
	@if command -v genhtml > /dev/null 2>&1; then \
		genhtml $(BUILD_DIR)/coverage.info --output-directory $(BUILD_DIR)/coverage_html \
			--title "KV32 SoC Coverage Report" \
			--show-details --legend \
			--rc genhtml_branch_coverage=1 2>&1 | grep -E "(Overall|Processing|Writing)" || true; \
		echo ""; \
		echo "==========================================" ; \
		echo "Coverage report generated successfully!" ; \
		echo "==========================================" ; \
		echo "  HTML Report: $(BUILD_DIR)/coverage_html/index.html" ; \
		echo "  Info file:   $(BUILD_DIR)/coverage.info" ; \
		echo "" ; \
		echo "Open report:" ; \
		echo "  open $(BUILD_DIR)/coverage_html/index.html" ; \
	else \
		echo "Warning: genhtml not found, generating annotated source only"; \
		verilator_coverage --annotate $(BUILD_DIR)/coverage_annotated $(BUILD_DIR)/objdir/coverage.dat; \
		echo ""; \
		echo "Coverage report generated:"; \
		echo "  Annotated sources: $(BUILD_DIR)/coverage_annotated/"; \
		echo "  Info file: $(BUILD_DIR)/coverage.info"; \
		echo ""; \
		echo "To generate HTML report, install lcov:"; \
		echo "  brew install lcov  # macOS"; \
		echo "  apt-get install lcov  # Ubuntu/Debian"; \
	fi
	@echo ""
	@echo "Coverage summary:"
	@verilator_coverage --rank $(BUILD_DIR)/objdir/coverage.dat 2>/dev/null | head -20
	@echo "=========================================="

# Target to run architectural tests (e.g., make arch-test-rv32i, make arch-test-setup)
# Forwards to verif/Makefile
arch-test-%:
	@$(MAKE) -C verif arch-test-$*

# Target to run FreeRTOS tests (e.g., make freerots-rtl-perf)
# Forwards to rtos/freertos/Makefile
freertos-%:
	@$(MAKE) -C rtos freertos-$*

# Run simulation
run: $(BUILD_TARGET)
	@echo "Running RISC-V SoC simulation..."
	@cd $(SIM_DIR) && ../$(BUILD_TARGET)
	@echo "Simulation complete!"

# Open waveform viewer
waves: run
	@echo "Opening waveform viewer..."
	@if command -v gtkwave > /dev/null; then \
		cd $(SIM_DIR) && gtkwave kv32soc.vcd & \
	else \
		echo "GTKWave not found. Please install it to view waveforms."; \
	fi

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(BUILD_DIR)
	@rm -f $(SIM_DIR)/kv32soc.vcd
	@rm -f $(SIM_DIR)/*.vcd
	@make -C rtos freertos-clean
	@make -C verif arch-test-clean
	@echo "Clean complete!"

# Clean only Spike plugin .so files
clean-spike-plugins:
	@echo "Cleaning Spike plugins..."
	@$(MAKE) -C $(SPIKE_DIR) clean BUILD_DIR=../$(BUILD_DIR)
	@echo "Done."

# Clean only test programs
clean-tests:
	@echo "Cleaning test programs..."
	@rm -f $(BUILD_DIR)/firmware.elf
	@rm -f $(BUILD_DIR)/firmware.dis
	@rm -f $(BUILD_DIR)/firmware.readelf
	@rm -f $(BUILD_DIR)/kv32soc.vcd
	@echo "Test clean complete!"

# Show environment info
info:
	@echo "=========================================="
	@echo "RISC-V SoC Project Configuration"
	@echo "=========================================="
	@echo "RISCV_PREFIX: $(RISCV_PREFIX)"
	@echo "VERILATOR:    $(VERILATOR)"
	@echo "SPIKE:         $(SPIKE)"
	@echo "SPIKE_INCLUDE: $(SPIKE_INCLUDE)"
	@echo "ZEPHYR_BASE:   $(ZEPHYR_BASE)"
	@echo "NUTTX_BASE:   $(NUTTX_BASE)"
	@echo "NUTTX_APPS:   $(NUTTX_APPS)"
	@echo "PATH_APPEND:  $(PATH_APPEND)"
	@echo ""
	@echo "Project Directories:"
	@echo "  RTL:       $(RTL_DIR)"
	@echo "  Testbench: $(TB_DIR)"
	@echo "  Sim:       $(SIM_DIR)"
	@echo "  Software:  $(SW_DIR)"
	@echo "  Build:     $(BUILD_DIR)"
	@echo "=========================================="

# Help target
help:
	@echo "=========================================="
	@echo "RISC-V SoC Project Build System"
	@echo "=========================================="
	@echo ""
	@echo "Main Targets:"
	@echo "  all        - Full correctness run: RTL + sim + compare + arch-tests"
	@echo "               (Use this to verify core correctness at default latency)"
	@echo "  verify-mem - AXI interface stress: runs compare-all + rtl-all across"
	@echo "               10 latency/port combinations (read=1/4/16, write=1/4/16,"
	@echo "               dual-port=0/1) to catch memory interface bugs"
	@echo "  build-rtl  - Build RTL with Verilator"
	@echo "  build-sim  - Build software simulator (kv32sim)"
	@echo "  clean      - Remove all build artifacts"
	@echo "  clean-tests- Remove only test program builds"
	@echo "  info       - Show environment configuration"
	@echo "  help       - Show this help message"
	@echo ""
	@echo "Test Program Targets:"
	@echo "  <test>        - Build test program (e.g., make hello)"
	@echo "  rtl-<test>    - Build and run test with RTL simulator"
	@echo "  rtl-all       - Build and run ALL tests with RTL simulator"
	@echo "  sim-<test>    - Build and run test with software simulator"
	@echo "  sim-all       - Build and run ALL tests with software simulator"
	@echo "  spike-<test>  - Build and run test with Spike (always uses Spike)"
	@echo "  spike-all     - Run SPIKE_TESTS under Spike with MMIO plugins"
	@echo "  build-spike-plugins - Build all Spike MMIO plugin .so files"
	@echo "  compare-<test>      - Run both RTL and sim, compare traces"
	@echo "  compare-all   - Compare traces for ALL tests"
	@echo "  coverage-<test>- Run test with coverage collection"
	@echo "  coverage-all  - Run ALL tests with coverage, generate report"
	@echo "  coverage-report- Generate coverage report from collected data"
	@echo ""
	@echo "Available Tests:"
	@for test in $(TEST_NAMES); do \
		echo "  - $$test"; \
	done
	@echo ""
	@echo "Configuration:"
	@echo "  Edit env.config to set toolchain paths"
	@echo ""
	@echo "Examples:"
	@echo "  make                 # Build RTL"
	@echo "  make all             # Run full correctness suite (RTL+sim+compare+arch)"
	@echo "  make verify-mem      # Stress AXI interface across 10 latency/port configs"
	@echo "  make hello           # Build hello test"
	@echo "  make rtl-hello       # Run hello test with RTL"
	@echo "  make rtl-all         # Run all tests with RTL"
	@echo "  make sim-uart        # Run uart test with software sim (kv32sim)"
	@echo "  make sim-all         # Run all tests with software sim"
	@echo "  make spike-hello           # Run hello test with Spike (shorthand)"
	@echo "  make SIM=spike sim-hello   # Run hello test with Spike + MMIO plugins"
	@echo "  make spike-all             # Run all Spike-compatible tests"
	@echo "  make spike-all SPIKE_TESTS=\"hello simple dhry\"  # Run a custom subset"
	@echo "  make build-spike-plugins   # Build all Spike MMIO plugin .so files"
	@echo "  make compare-simple  # Compare RTL vs sim traces"
	@echo "  make compare-all     # Compare traces for all tests"
	@echo "  make coverage-simple # Run simple test with coverage"
	@echo "  make coverage-all    # Run all tests with coverage"
	@echo "  make coverage-report # Generate coverage report"
	@echo "  make clean           # Clean all build files"
	@echo "  make info            # Show configuration"
	@echo ""
	@echo "Debug Options:"
	@echo "  make DEBUG=1 rtl-simple  # Run with debug messages (rebuilds RTL)"
	@echo "  make TRACE=1 rtl-simple  # Enable instruction trace"
	@echo "  make WAVE=1 rtl-simple   # Enable FST waveform dump"
	@echo "  make SIM=spike sim-hello # Use Spike with MMIO plugins (RTL-compatible binary)"
	@echo ""
	@echo "Output Structure:"
	@echo "  build/firmware.elf          - Executable"
	@echo "  build/firmware.dis          - Disassembly"
	@echo "  build/firmware.readelf      - ELF info"
	@echo "  build/kv32soc.fst           - Waveform (RTL, FST format)"
	@echo "  build/coverage_html/        - Coverage report (HTML)"
	@echo "  build/coverage.info         - Coverage data (lcov format)"
	@echo ""
	@make -C verif help
	@make -C rtos freertos-help
