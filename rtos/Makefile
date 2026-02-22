# Load environment configuration (must define RISCV_PREFIX and VERILATOR)
-include ../env.config

export RISCV_PREFIX
export VERILATOR
export SPIKE

# Append additional paths to PATH if specified
ifdef PATH_APPEND
export PATH     := $(PATH_APPEND):$(PATH)
endif

# ============================================================================
# Variable Definitions
# ============================================================================

PROJECT_ROOT     = $(realpath ..)
BUILD_DIR        = $(PROJECT_ROOT)/build
FREERTOS_DIR     = $(PROJECT_ROOT)/rtos/freertos
FREERTOS_SAMPLES = $(FREERTOS_DIR)/samples
FREERTOS_SYS     = $(FREERTOS_DIR)/sys
FREERTOS_PORT    = $(FREERTOS_DIR)/portable/RISC-V
FREERTOS_INCLUDE = $(FREERTOS_DIR)/include

# FreeRTOS source files
FREERTOS_SOURCES = \
	$(FREERTOS_DIR)/tasks.c \
	$(FREERTOS_DIR)/queue.c \
	$(FREERTOS_DIR)/list.c \
	$(FREERTOS_DIR)/timers.c \
	$(FREERTOS_DIR)/event_groups.c \
	$(FREERTOS_DIR)/stream_buffer.c \
	$(FREERTOS_PORT)/port.c \
	$(FREERTOS_PORT)/portASM.S

# FreeRTOS heap implementation (heap_3 uses malloc/free)
FREERTOS_HEAP = $(FREERTOS_DIR)/portable/MemMang/heap_3.c

ifneq ($(wildcard $(FREERTOS_HEAP)),)
FREERTOS_SOURCES += $(FREERTOS_HEAP)
endif

# FreeRTOS compiler flags
FREERTOS_CFLAGS   = -march=$(ARCH) -mabi=$(ABI) -O2 -g -Wall
FREERTOS_CFLAGS  += -ffreestanding -nostartfiles
FREERTOS_CFLAGS  += -ffunction-sections -fdata-sections
FREERTOS_CFLAGS  += -I$(FREERTOS_INCLUDE)
FREERTOS_CFLAGS  += -I$(FREERTOS_PORT)
FREERTOS_CFLAGS  += -I$(FREERTOS_SYS)
FREERTOS_CFLAGS  += -I$(FREERTOS_SAMPLES)/include
FREERTOS_CFLAGS  += -I$(PROJECT_ROOT)/sw/include
FREERTOS_LDFLAGS  = -T $(FREERTOS_SYS)/freertos_link.ld
FREERTOS_LDFLAGS += -Wl,--gc-sections
FREERTOS_LDFLAGS += -lc -lgcc

# Architecture/ABI
ARCH             ?= rv32ima_zicsr
ABI              ?= ilp32

# Simulator (rv32sim or spike)
SIM              ?= rv32sim
MAX_CYCLES       ?= 0

# Trace compare script
TRACE_COMPARE    ?= $(PROJECT_ROOT)/scripts/trace_compare.py

# RISC-V toolchain
RISCV_PREFIX     ?= riscv32-unknown-elf-
CC                = $(RISCV_PREFIX)gcc
CXX               = $(RISCV_PREFIX)g++
OBJDUMP           = $(RISCV_PREFIX)objdump
OBJCOPY           = $(RISCV_PREFIX)objcopy
READELF           = $(RISCV_PREFIX)readelf

# ============================================================================
# Build Targets
# ============================================================================

.PHONY: all build-rtl clean help

# Default target
all: help

# Build RTL via project root Makefile
build-rtl:
	@$(MAKE) -C $(PROJECT_ROOT) build-rtl

# Clean build artifacts (delegates to root)
clean:
	@$(MAKE) -C $(PROJECT_ROOT) clean

# ============================================================================
# Help
# ============================================================================

.PHONY: freertos freertos-help

help: freertos-help

freertos-help:
	@echo ""
	@echo "=========================================="
	@echo "FreeRTOS Integration"
	@echo "=========================================="
	@echo ""
	@echo "FreeRTOS is a real-time operating system kernel for embedded systems."
	@echo "This project includes FreeRTOS with RISC-V port and sample applications."
	@echo ""
	@echo "Available FreeRTOS Commands:"
	@echo "  make freertos-<test>         - Build FreeRTOS test sample"
	@echo "  make freertos-rtl-<test>     - Run FreeRTOS test in RTL simulation"
	@echo "  make freertos-sim-<test>     - Run FreeRTOS test in ISS simulator"
	@echo "  make freertos-compare-<test> - Compare FreeRTOS RTL vs Spike traces"
	@echo ""
	@echo "Examples:"
	@echo "  make freertos-rtl-simple TRACE=1 MAX_CYCLES=0"
	@echo "  make freertos-sim-simple"
	@echo "  make freertos-compare-simple"
	@echo ""
	@echo "Available FreeRTOS Samples:"
	@ls -1 $(FREERTOS_SAMPLES)/*.c 2>/dev/null | xargs -n1 basename | sed 's/\.c$$//' | sed 's/^/  /' || echo "  (none found)"
	@echo ""
	@echo "FreeRTOS Directory Structure:"
	@echo "  Source:   $(FREERTOS_DIR)"
	@echo "  Samples:  $(FREERTOS_SAMPLES)"
	@echo "  Port:     $(FREERTOS_PORT)"
	@echo "  System:   $(FREERTOS_SYS)"
	@echo ""
	@echo "For more information, see: $(FREERTOS_DIR)/README.md"
	@echo ""

# ============================================================================
# RTL Simulation
# ============================================================================

.PHONY: freertos-rtl-%
freertos-rtl-%:
	@if [ ! -d $(FREERTOS_SAMPLES)/$* ]; then \
		echo "Error: FreeRTOS sample '$*' not found"; \
		echo "Expected directory: $(FREERTOS_SAMPLES)/$*"; \
		echo "Available samples:"; \
		ls -1d $(FREERTOS_SAMPLES)/* 2>/dev/null | grep -v include | xargs -n1 basename | sed 's/^/  /' || echo "  (none found)"; \
		exit 1; \
	fi
ifdef DEBUG
    @echo "=========================================="
    @echo "DEBUG=$(DEBUG) specified - rebuilding RTL"
    @echo "=========================================="
    @$(MAKE) clean
    @$(MAKE) build-rtl DEBUG=$(DEBUG)
else
	@$(MAKE) build-rtl
endif
	@$(MAKE) freertos-$*
	@cd $(BUILD_DIR) && ./rv32soc \
        $(if $(TRACE),--trace) \
        $(if $(filter 1 fst,$(WAVE)),--wave=fst) \
        $(if $(filter vcd,$(WAVE)),--wave=vcd) \
        $(if $(filter-out 0,$(MAX_CYCLES)),--instructions=$(MAX_CYCLES)) \
        freertos-$*.elf
	@echo ""
	@if [ "$(TRACE)" = "1" ]; then \
		echo "Trace saved to: $(BUILD_DIR)/rtl_trace.txt"; \
	fi
	@if [ "$(WAVE)" = "1" ] || [ "$(WAVE)" = "fst" ]; then \
		echo "Waveform saved to: $(BUILD_DIR)/rv32soc.fst"; \
	elif [ "$(WAVE)" = "vcd" ]; then \
		echo "Waveform saved to: $(BUILD_DIR)/rv32soc.vcd"; \
	fi
	@if [ "$(TRACE)" != "1" ] && [ "$(WAVE)" = "" ]; then \
		echo "Use TRACE=1 for instruction trace, WAVE=fst or WAVE=vcd for waveform dump"; \
	fi
	@echo "=== FreeRTOS test complete ==="

# ============================================================================
# Software Simulation (ISS)
# ============================================================================

.PHONY: freertos-sim-%
freertos-sim-%:
	@if [ ! -d $(FREERTOS_SAMPLES)/$* ]; then \
		echo "Error: FreeRTOS sample '$*' not found"; \
		echo "Expected directory: $(FREERTOS_SAMPLES)/$*"; \
		echo "Available samples:"; \
		ls -1d $(FREERTOS_SAMPLES)/* 2>/dev/null | grep -v include | xargs -n1 basename | sed 's/^/  /' || echo "  (none found)"; \
		exit 1; \
	fi
	@$(MAKE) -C $(PROJECT_ROOT) build-sim
	@$(MAKE) freertos-$*
	@if [ "$(SIM)" = "spike" ]; then \
        cd $(BUILD_DIR) && spike \
            --isa=rv32ima -m0x80000000:0x200000 \
            $(if $(TRACE),--log-commits --log=sim_trace.txt) \
            $(if $(filter-out 0,$(MAX_CYCLES)),--instructions=$(MAX_CYCLES)) \
            freertos-$*.elf; \
    else \
        cd $(BUILD_DIR) && ./$(SIM) \
            --isa=rv32ima -m0x80000000:0x200000 \
            $(if $(TRACE),--rtl-trace --log=sim_trace.txt) \
            $(if $(filter-out 0,$(MAX_CYCLES)),--instructions=$(MAX_CYCLES)) \
            freertos-$*.elf; \
    fi
	@if [ "$(TRACE)" = "1" ]; then \
        echo "Trace saved to: $(BUILD_DIR)/sim_trace.txt"; \
    else \
        echo "Use TRACE=1 to enable instruction trace"; \
    fi

# ============================================================================
# Compare (RTL vs ISS trace)
# ============================================================================

.PHONY: freertos-compare-%
freertos-compare-%:
	@if [ ! -d $(FREERTOS_SAMPLES)/$* ]; then \
		echo "Error: FreeRTOS sample '$*' not found"; \
		echo "Expected directory: $(FREERTOS_SAMPLES)/$*"; \
		echo "Available samples:"; \
		ls -1d $(FREERTOS_SAMPLES)/* 2>/dev/null | grep -v include | xargs -n1 basename | sed 's/^/  /' || echo "  (none found)"; \
		exit 1; \
	fi
	@$(MAKE) -C $(PROJECT_ROOT) build-sim
	@$(MAKE) freertos-$*
	@echo "Step 1: Running RTL simulator with trace..."
	@-$(MAKE) freertos-rtl-$* TRACE=1
	@echo "Step 2: Running software simulator with trace..."
	@-$(MAKE) freertos-sim-$* TRACE=1
	@echo "Step 3: Comparing traces..."
	@if [ ! -f $(TRACE_COMPARE) ]; then \
        echo "Error: $(TRACE_COMPARE) not found"; \
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
	@python3 $(TRACE_COMPARE) $(BUILD_DIR)/rtl_trace.txt $(BUILD_DIR)/sim_trace.txt

.PHONY: freertos-clean
freertos-clean:

# ============================================================================
# Build (ELF compilation)
# ============================================================================

.PHONY: freertos-%
freertos-%:
	@if [ ! -d $(FREERTOS_SAMPLES)/$* ]; then \
		echo "Error: FreeRTOS sample '$*' not found"; \
		echo "Expected directory: $(FREERTOS_SAMPLES)/$*"; \
		echo "Available samples:"; \
		ls -1d $(FREERTOS_SAMPLES)/* 2>/dev/null | grep -v include | xargs -n1 basename | sed 's/^/  /' || echo "  (none found)"; \
		exit 1; \
	fi
	@mkdir -p $(BUILD_DIR)
	$(CC) $(FREERTOS_CFLAGS) $(FREERTOS_LDFLAGS) \
		-Wl,-Map=$(BUILD_DIR)/freertos-$*.map \
		$(FREERTOS_SYS)/freertos_start.S \
		$(FREERTOS_SYS)/freertos_syscall.c \
		$(FREERTOS_SAMPLES)/$*/*.c \
		$(FREERTOS_SOURCES) \
		-o $(BUILD_DIR)/freertos-$*.elf
	@echo "Generating disassembly..."
	$(OBJDUMP) -D $(BUILD_DIR)/freertos-$*.elf > $(BUILD_DIR)/freertos-$*.dis
	@echo "Generating readelf info..."
	$(READELF) -a $(BUILD_DIR)/freertos-$*.elf > $(BUILD_DIR)/freertos-$*.readelf
	@echo "=== FreeRTOS test built successfully ==="
	@echo ""

