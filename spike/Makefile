# spike/Makefile – Build Spike MMIO plugins for the KV32 SoC
#
# Usage:
#   make                            # build all plugins into ../build/
#   make BUILD_DIR=../build         # explicit build directory
#   make SPIKE_INCLUDE=/opt/spike/include   # use real Spike headers
#   make clean                      # remove built .so files
#
# Each plugin is compiled as a position-independent shared library.
# Plugins are loaded by Spike at runtime via --extlib=<path>.so.
# Register constants are sourced from ../sw/include/kv_platform.h.
#
# NOTE: On macOS, Spike must be built with -Wl,-export_dynamic or similar
#       to export the register_mmio_plugin symbol for plugins to work at runtime.
#       Standard Spike builds may not have this enabled. If you encounter
#       "symbol not found '_register_mmio_plugin'" errors at runtime, you'll
#       need to rebuild Spike with proper symbol exports.

# ── directories ───────────────────────────────────────────────────────────────
SPIKE_DIR  := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
BUILD_DIR  ?= ../build
SW_INCLUDE  = ../sw/include

# Optional: path to real Spike headers (e.g. /opt/spike/include).
# If available and contains riscv/mmio_plugin.h, use instead of our shim.
SPIKE_INCLUDE ?=

# ── compiler flags ────────────────────────────────────────────────────────────
CXX      ?= g++
CXXFLAGS  = -std=c++14 -O2 -fPIC -shared
CXXFLAGS += -I$(SPIKE_DIR) -I$(SW_INCLUDE)
CXXFLAGS += -DKV_PLATFORM_NO_INLINE_HELPERS
LDFLAGS   = -ldl

# On macOS, allow undefined symbols to be resolved at runtime
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  LDFLAGS += -undefined dynamic_lookup
endif

# If real Spike headers are present, use them instead of our shim.
ifneq ($(SPIKE_INCLUDE),)
  ifeq ($(wildcard $(SPIKE_INCLUDE)/riscv/mmio_plugin.h),$(SPIKE_INCLUDE)/riscv/mmio_plugin.h)
    CXXFLAGS += -DSPIKE_INCLUDE -I$(SPIKE_INCLUDE)
  endif
endif

# ── targets ───────────────────────────────────────────────────────────────────
PLUGINS = \
  $(BUILD_DIR)/spike_plugin_magic.so   \
  $(BUILD_DIR)/spike_plugin_plic.so    \
  $(BUILD_DIR)/spike_plugin_clint.so   \
  $(BUILD_DIR)/spike_plugin_uart.so    \
  $(BUILD_DIR)/spike_plugin_spi.so     \
  $(BUILD_DIR)/spike_plugin_i2c.so     \
  $(BUILD_DIR)/spike_plugin_dma.so

.PHONY: all clean

all: $(PLUGINS)

# Pattern rule: plugin_%.cc → build/spike_plugin_%.so
$(BUILD_DIR)/spike_plugin_%.so: $(SPIKE_DIR)/plugin_%.cc $(SPIKE_DIR)/mmio_plugin_api.h
	@mkdir -p $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -o $@ $< $(LDFLAGS)
	@echo "  Built $@"

clean:
	rm -f $(PLUGINS)
