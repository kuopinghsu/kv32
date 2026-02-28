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

# Architecture/ABI
ARCH             ?= rv32ima_zicsr
ABI              ?= ilp32

# Simulator (kv32sim or spike)
SIM              ?= kv32sim
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
all: freertos-help

# Build RTL via project root Makefile
build-rtl:
	@$(MAKE) -C $(PROJECT_ROOT) build-rtl

# Clean build artifacts (delegates to root)
clean:
	@$(MAKE) -C $(PROJECT_ROOT) clean

include Makefile.freertos
include Makefile.zephyr

