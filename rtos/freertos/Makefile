# FreeRTOS framework build-only targets.

-include ../../env.config

export RISCV_PREFIX

PROJECT_ROOT = $(realpath ../..)
BUILD_DIR    = $(PROJECT_ROOT)/build
ARCH ?= rv32imac_zicsr
ABI  ?= ilp32

RISCV_PREFIX ?= riscv32-unknown-elf-
CC      = $(RISCV_PREFIX)gcc
OBJDUMP = $(RISCV_PREFIX)objdump
READELF = $(RISCV_PREFIX)readelf

FREERTOS_DIR     = $(PROJECT_ROOT)/rtos/freertos
FREERTOS_SAMPLES = $(FREERTOS_DIR)/samples
FREERTOS_SYS     = $(FREERTOS_DIR)/sys
FREERTOS_PORT    = $(FREERTOS_DIR)/portable/RISC-V
FREERTOS_INCLUDE = $(FREERTOS_DIR)/include

FREERTOS_SOURCES = \
	$(FREERTOS_DIR)/tasks.c \
	$(FREERTOS_DIR)/queue.c \
	$(FREERTOS_DIR)/list.c \
	$(FREERTOS_DIR)/timers.c \
	$(FREERTOS_DIR)/event_groups.c \
	$(FREERTOS_DIR)/stream_buffer.c \
	$(FREERTOS_PORT)/port.c \
	$(FREERTOS_PORT)/portASM.S

FREERTOS_HEAP = $(FREERTOS_DIR)/portable/MemMang/heap_3.c
ifneq ($(wildcard $(FREERTOS_HEAP)),)
FREERTOS_SOURCES += $(FREERTOS_HEAP)
endif

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

SAMPLE_DIRS  = $(filter-out $(FREERTOS_SAMPLES)/include,$(wildcard $(FREERTOS_SAMPLES)/*))
SAMPLE_NAMES = $(notdir $(SAMPLE_DIRS))

.PHONY: help list-tests build clean

help:
	@echo "FreeRTOS framework build targets"
	@echo "  make -C rtos/freertos build TEST=<sample|all>"
	@echo "  make -C rtos/freertos list-tests"
	@echo "  make -C rtos/freertos clean"
	@echo ""
	@echo "Run through root shared targets:"
	@echo "  make rtl-freertos-<sample|all>"
	@echo "  make sim-freertos-<sample|all>"
	@echo "  make spike-freertos-<sample|all>"
	@echo "  make compare-freertos-<sample|all>"

list-tests:
	@for t in $(SAMPLE_NAMES); do echo $$t; done

build:
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
	@if [ ! -d $(FREERTOS_SAMPLES)/$(TEST) ]; then \
		echo "Error: FreeRTOS sample '$(TEST)' not found"; \
		exit 1; \
	fi
	@mkdir -p $(BUILD_DIR)
	$(CC) $(FREERTOS_CFLAGS) $(FREERTOS_LDFLAGS) \
		-Wl,-Map=$(BUILD_DIR)/freertos-$(TEST).map \
		$(FREERTOS_SYS)/freertos_start.S \
		$(FREERTOS_SYS)/freertos_syscall.c \
		$(FREERTOS_SAMPLES)/$(TEST)/*.c \
		$(FREERTOS_SOURCES) \
		-o $(BUILD_DIR)/freertos-$(TEST).elf
	@$(OBJDUMP) -D $(BUILD_DIR)/freertos-$(TEST).elf > $(BUILD_DIR)/freertos-$(TEST).dis
	@$(READELF) -a $(BUILD_DIR)/freertos-$(TEST).elf > $(BUILD_DIR)/freertos-$(TEST).readelf

clean:
	@rm -f $(BUILD_DIR)/freertos-*.elf
	@rm -f $(BUILD_DIR)/freertos-*.map
	@rm -f $(BUILD_DIR)/freertos-*.dis
	@rm -f $(BUILD_DIR)/freertos-*.readelf
