# KV32 software framework build logic (bare-metal sw/ tests)

# Load environment configuration
-include ../env.config

# Export environment variables used by recursive builds
export RISCV_PREFIX

PROJECT_ROOT = $(realpath ..)
BUILD_DIR    = $(PROJECT_ROOT)/build
SW_DIR       = $(PROJECT_ROOT)/sw

RISCV_PREFIX ?= riscv32-unknown-elf-
CC      = $(RISCV_PREFIX)gcc
CXX     = $(RISCV_PREFIX)g++
OBJDUMP = $(RISCV_PREFIX)objdump
READELF = $(RISCV_PREFIX)readelf

ICACHE_EN ?= 1
DCACHE_EN ?= 1

CFLAGS = -march=rv32imac_zicsr -mabi=ilp32 -O2 -g
CFLAGS += -Wall -Werror -ffreestanding
CFLAGS += -nostartfiles
CFLAGS += -ffunction-sections -fdata-sections
CFLAGS += -I$(SW_DIR)/common -I$(SW_DIR)/include
CFLAGS += -DICACHE_EN=$(ICACHE_EN)
CFLAGS += -DDCACHE_EN=$(DCACHE_EN)

CXXFLAGS = $(CFLAGS) -fno-exceptions -fno-rtti -fno-use-cxa-atexit

LDFLAGS = -T$(SW_DIR)/common/link.ld -Wl,--gc-sections
LDFLAGS += -Wl,--wrap=fflush
LDFLAGS += -lc -lgcc -lm

COMMON_SRCS = $(SW_DIR)/common/start.S $(SW_DIR)/common/syscall.c $(SW_DIR)/common/trap.c \
              $(SW_DIR)/common/kv_irq.c \
              $(SW_DIR)/common/puts.c $(SW_DIR)/common/putc.c \
              $(SW_DIR)/common/user_hook.c

# Optional per-test software makefile include.
ifneq ($(strip $(TEST)),)
ifneq ($(wildcard $(SW_DIR)/$(TEST)/makefile.mak),)
include $(SW_DIR)/$(TEST)/makefile.mak
endif
endif

# Find all test directories (exclude common and include)
TEST_DIRS  = $(shell find $(SW_DIR) -mindepth 1 -maxdepth 1 -type d ! -name common ! -name include)
TEST_NAMES = $(notdir $(TEST_DIRS))

SW_BUILD_PARAMS = ICACHE_EN=$(ICACHE_EN) DCACHE_EN=$(DCACHE_EN)
SW_PARAMS_STAMP = $(BUILD_DIR)/.sw_build_params

.PHONY: help list-tests build build-spike build-all build-spike-all FORCE

help:
	@echo "KV32 SW Framework Makefile"
	@echo "  make -C sw build TEST=<name>          # build build/<name>.elf"
	@echo "  make -C sw build-spike TEST=<name>    # build build/<name>-spike.elf"
	@echo "  make -C sw build-all                  # build all sw tests"
	@echo "  make -C sw list-tests                 # print available tests"

list-tests:
	@for t in $(TEST_NAMES); do echo $$t; done

$(SW_PARAMS_STAMP): FORCE
	@mkdir -p $(BUILD_DIR)
	@printf '%s' "$(SW_BUILD_PARAMS)" | cmp -s - $@ || printf '%s' "$(SW_BUILD_PARAMS)" > $@

FORCE:

.SECONDEXPANSION:
$(BUILD_DIR)/%.elf: $(COMMON_SRCS) $(SW_DIR)/common/link.ld $(SW_PARAMS_STAMP) \
                    $$(wildcard $(SW_DIR)/$$*/*.c $(SW_DIR)/$$*/*.cpp $(SW_DIR)/$$*/*.h $(SW_DIR)/$$*/*.S)
	@$(MAKE) --no-print-directory __build-test TEST=$* OUT=$@ DIS_OUT=$(BUILD_DIR)/$*.dis READELF_OUT=$(BUILD_DIR)/$*.readelf

$(BUILD_DIR)/%-spike.elf: $(COMMON_SRCS) $(SW_DIR)/common/link.ld $(SW_PARAMS_STAMP) \
                          $$(wildcard $(SW_DIR)/$$*/*.c $(SW_DIR)/$$*/*.cpp $(SW_DIR)/$$*/*.h $(SW_DIR)/$$*/*.S)
	@$(MAKE) --no-print-directory __build-test TEST=$* OUT=$@ HTIF=1 DIS_OUT=$(BUILD_DIR)/$*-spike.dis READELF_OUT=$(BUILD_DIR)/$*-spike.readelf

build:
	@if [ -z "$(TEST)" ]; then \
		echo "Error: TEST is required (example: make -C sw build TEST=hello)"; \
		exit 1; \
	fi
	@$(MAKE) --no-print-directory $(BUILD_DIR)/$(TEST).elf

build-spike:
	@if [ -z "$(TEST)" ]; then \
		echo "Error: TEST is required (example: make -C sw build-spike TEST=hello)"; \
		exit 1; \
	fi
	@$(MAKE) --no-print-directory $(BUILD_DIR)/$(TEST)-spike.elf

build-all:
	@failed=0; \
	for test in $(TEST_NAMES); do \
		if ! $(MAKE) --no-print-directory build TEST=$$test; then \
			failed=1; \
		fi; \
	done; \
	if [ $$failed -ne 0 ]; then exit 1; fi

build-spike-all:
	@failed=0; \
	for test in $(TEST_NAMES); do \
		if ! $(MAKE) --no-print-directory build-spike TEST=$$test; then \
			failed=1; \
		fi; \
	done; \
	if [ $$failed -ne 0 ]; then exit 1; fi

.PHONY: __build-test
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
	@if [ -n "$$(find $(SW_DIR)/$(TEST) -maxdepth 1 -name '*.cpp' 2>/dev/null)" ]; then \
		echo "Detected C++ source files, using g++"; \
		$(CXX) $(CXXFLAGS) $(EXTRA_CFLAGS) $(if $(filter 1,$(HTIF)),-DUSE_HTIF) \
			$(COMMON_SRCS) \
			$$(find $(SW_DIR)/$(TEST) -maxdepth 1 -name '*.cpp') \
			$(LDFLAGS) \
			-o $(OUT); \
	elif [ -n "$$(find $(SW_DIR)/$(TEST) -maxdepth 1 -name '*.c' 2>/dev/null)" ]; then \
		echo "Detected C source files, using gcc"; \
		$(CC) $(CFLAGS) $(EXTRA_CFLAGS) $(if $(filter 1,$(HTIF)),-DUSE_HTIF) \
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
