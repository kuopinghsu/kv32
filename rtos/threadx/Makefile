# ThreadX framework build-only targets.

-include ../../env.config

export RISCV_PREFIX

PROJECT_ROOT = $(realpath ../..)
BUILD_DIR    = $(PROJECT_ROOT)/build
THREADX_OBJ_DIR   = $(BUILD_DIR)/threadx
ARCH ?= rv32imac_zicsr
ABI  ?= ilp32

RISCV_PREFIX ?= riscv32-unknown-elf-
CC      = $(RISCV_PREFIX)gcc
OBJDUMP = $(RISCV_PREFIX)objdump
READELF = $(RISCV_PREFIX)readelf

THREADX_DIR      = $(PROJECT_ROOT)/rtos/threadx
THREADX_COMMON   = $(THREADX_DIR)/common
THREADX_PORT     = $(THREADX_DIR)/ports/kv32
THREADX_SAMPLES  = $(THREADX_DIR)/samples

THREADX_COMMON_SRCS = $(wildcard $(THREADX_COMMON)/src/*.c)
THREADX_PORT_SRCS   = \
	$(THREADX_PORT)/tx_port.c \
	$(THREADX_PORT)/tx_port_asm.S

COMMON_SRCS = \
	$(PROJECT_ROOT)/sw/common/start.S \
	$(PROJECT_ROOT)/sw/common/syscall.c \
	$(PROJECT_ROOT)/sw/common/trap.c \
	$(PROJECT_ROOT)/sw/common/kv_irq.c \
	$(PROJECT_ROOT)/sw/common/puts.c \
	$(PROJECT_ROOT)/sw/common/putc.c \
	$(PROJECT_ROOT)/sw/common/user_hook.c

THREADX_CFLAGS  = -march=$(ARCH) -mabi=$(ABI) -O2 -g
THREADX_CFLAGS += -ffreestanding -nostartfiles
THREADX_CFLAGS += -ffunction-sections -fdata-sections
THREADX_CFLAGS += -DTX_INCLUDE_USER_DEFINE_FILE
THREADX_CFLAGS += -I$(THREADX_COMMON)/inc
THREADX_CFLAGS += -I$(THREADX_PORT)
THREADX_CFLAGS += -I$(THREADX_SAMPLES)/include
THREADX_CFLAGS += -I$(PROJECT_ROOT)/sw/include

THREADX_LDFLAGS  = -T $(PROJECT_ROOT)/sw/common/link.ld
THREADX_LDFLAGS += -Wl,--gc-sections
THREADX_LDFLAGS += -lc -lgcc -lm

SAMPLE_DIRS  = $(filter-out $(THREADX_SAMPLES)/include,$(wildcard $(THREADX_SAMPLES)/*))
SAMPLE_NAMES = $(notdir $(SAMPLE_DIRS))

.PHONY: help list-tests build clean

help:
	@echo "ThreadX framework build targets"
	@echo "  make -C rtos/threadx build TEST=<sample|all>"
	@echo "  make -C rtos/threadx list-tests"
	@echo "  make -C rtos/threadx clean"
	@echo ""
	@echo "Run through root shared targets:"
	@echo "  make rtl-threadx-<sample|all>"
	@echo "  make sim-threadx-<sample|all>"
	@echo "  make spike-threadx-<sample|all>"
	@echo "  make compare-threadx-<sample|all>"

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
	@if [ ! -d $(THREADX_SAMPLES)/$(TEST) ]; then \
		echo "Error: ThreadX sample '$(TEST)' not found"; \
		exit 1; \
	fi
	@mkdir -p $(BUILD_DIR) $(THREADX_OBJ_DIR)
	@set -e; \
	srcs="$(COMMON_SRCS) $(THREADX_SAMPLES)/$(TEST)/*.c $(THREADX_COMMON_SRCS) $(THREADX_PORT_SRCS)"; \
	total=0; \
	for src in $$srcs; do \
		total=$$((total + 1)); \
	done; \
	printf '[build] CC %d objects -> %s\n' $$total '$(THREADX_OBJ_DIR)'; \
	next_pct=10; \
	count=0; \
	objs=""; \
	for src in $$srcs; do \
		count=$$((count + 1)); \
		base=$$(basename "$$src"); \
		stem=$${base%.*}; \
		obj=$(THREADX_OBJ_DIR)/$(TEST)_$${stem}.o; \
		$(CC) $(THREADX_CFLAGS) -c "$$src" -o "$$obj"; \
		objs="$$objs $$obj"; \
		pct=$$((count * 100 / total)); \
		if [ $$pct -ge $$next_pct ]; then \
			printf '[build] %d%% (%d/%d)\n' $$next_pct $$count $$total; \
			next_pct=$$((next_pct + 10)); \
		fi; \
	done; \
	printf '[link] LD %s\n' '$(BUILD_DIR)/threadx-$(TEST).elf'; \
	$(CC) $(THREADX_CFLAGS) $(THREADX_LDFLAGS) \
		-Wl,-Map=$(BUILD_DIR)/threadx-$(TEST).map \
		$$objs \
		-o $(BUILD_DIR)/threadx-$(TEST).elf
	@printf '[post] generate dis/readelf in %s\n' '$(BUILD_DIR)'
	@$(OBJDUMP) -D $(BUILD_DIR)/threadx-$(TEST).elf > $(BUILD_DIR)/threadx-$(TEST).dis
	@$(READELF) -a $(BUILD_DIR)/threadx-$(TEST).elf > $(BUILD_DIR)/threadx-$(TEST).readelf

clean:
	@rm -f $(BUILD_DIR)/threadx-*.elf
	@rm -f $(BUILD_DIR)/threadx-*.map
	@rm -f $(BUILD_DIR)/threadx-*.dis
	@rm -f $(BUILD_DIR)/threadx-*.readelf
	@rm -rf $(THREADX_OBJ_DIR)
