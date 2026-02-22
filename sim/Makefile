# Makefile for RV32IMAC Software Simulator
# Builds rv32sim with GDB stub support

# Load environment configuration
-include ../env.config

# Directories
BUILD_DIR = ../build

# Compiler settings
CC = gcc
CXX = g++
CFLAGS = -std=c11 -O2 -Wall
CXXFLAGS = -std=c++14 -O2 -Wall

# Source files
SOURCES = rv32sim.cpp riscv-dis.cpp gdb_stub.c device.cpp
HEADERS = rv32sim.h riscv-dis.h gdb_stub.h device.h
OBJECTS = $(BUILD_DIR)/rv32sim.o $(BUILD_DIR)/riscv-dis.o $(BUILD_DIR)/gdb_stub.o $(BUILD_DIR)/device.o

# Target binary
TARGET = $(BUILD_DIR)/rv32sim

# ============================================================================
# Build targets
# ============================================================================

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(OBJECTS) | $(BUILD_DIR)
	@echo "Linking $(TARGET)..."
	$(CXX) $(CXXFLAGS) -o $@ $(OBJECTS)
	@echo "Build complete: $(TARGET)"

$(BUILD_DIR)/rv32sim.o: rv32sim.cpp rv32sim.h riscv-dis.h gdb_stub.h device.h | $(BUILD_DIR)
	@echo "Compiling rv32sim.cpp..."
	$(CXX) $(CXXFLAGS) -c -o $@ rv32sim.cpp

$(BUILD_DIR)/riscv-dis.o: riscv-dis.cpp riscv-dis.h | $(BUILD_DIR)
	@echo "Compiling riscv-dis.cpp..."
	$(CXX) $(CXXFLAGS) -c -o $@ riscv-dis.cpp

$(BUILD_DIR)/gdb_stub.o: gdb_stub.c gdb_stub.h | $(BUILD_DIR)
	@echo "Compiling gdb_stub.c..."
	$(CC) $(CFLAGS) -c -o $@ gdb_stub.c

$(BUILD_DIR)/device.o: device.cpp device.h | $(BUILD_DIR)
	@echo "Compiling device.cpp..."
	$(CXX) $(CXXFLAGS) -c -o $@ device.cpp

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

clean:
	@echo "Cleaning simulator build artifacts..."
	@rm -f $(OBJECTS) $(TARGET)
	@echo "Clean complete"

# ============================================================================
# Help
# ============================================================================

.PHONY: help
help:
	@echo "RV32IMAC Software Simulator Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  all     - Build rv32sim simulator (default)"
	@echo "  clean   - Remove build artifacts"
	@echo "  help    - Show this help message"
	@echo ""
	@echo "Output:"
	@echo "  $(TARGET)"
