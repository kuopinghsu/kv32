// ============================================================================
// File: elfloader.h
// Project: KV32 RISC-V Processor
// Description: ELF File Loader Header
//
// DPI-C interface for loading ELF files into simulation memory.
// ============================================================================

#ifndef ELFLOADER_H
#define ELFLOADER_H

#include <stdint.h>
#include <string>
#include <map>

// Symbol table entry
struct Symbol {
    std::string name;
    uint32_t addr;
    uint32_t size;
};

// Global variables for special symbols
extern uint32_t g_tohost_addr;
extern uint32_t g_fromhost_addr;
extern std::map<std::string, Symbol> g_symbols;

// Memory configuration (set before load_program, defaults to 0x80000000, 2MB)
extern uint32_t g_mem_base;
extern uint32_t g_mem_size;

// Load ELF file into memory
bool load_elf(void* dut, const std::string& filename);

// Load binary file into memory (legacy support)
bool load_bin(void* dut, const std::string& filename);

// Auto-detect and load program (ELF or binary)
bool load_program(void* dut, const std::string& filename);

#endif // ELFLOADER_H
