// ============================================================================
// File: elfloader.cpp
// Project: KV32 RISC-V Processor
// Description: ELF File Loader for Simulation
//
// Loads RISC-V ELF binaries into simulated memory using DPI-C interface.
// Parses ELF headers, program headers, and loads sections into memory.
// ============================================================================

#include "elfloader.h"
#include "svdpi.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

// DPI-C imported functions from SystemVerilog
extern "C" {
    void mem_write_byte(int addr, char data);
    char mem_read_byte(int addr);
}

// Global variables for special symbols
uint32_t g_tohost_addr = 0;
uint32_t g_fromhost_addr = 0;
std::map<std::string, Symbol> g_symbols;

// Memory configuration (defaults match the SV axi_memory instance)
uint32_t g_mem_base = 0x80000000;
uint32_t g_mem_size = 2 * 1024 * 1024;

// ELF file structures
#define EI_NIDENT 16

struct Elf32_Ehdr {
    unsigned char e_ident[EI_NIDENT];
    uint16_t e_type;
    uint16_t e_machine;
    uint32_t e_version;
    uint32_t e_entry;
    uint32_t e_phoff;
    uint32_t e_shoff;
    uint32_t e_flags;
    uint16_t e_ehsize;
    uint16_t e_phentsize;
    uint16_t e_phnum;
    uint16_t e_shentsize;
    uint16_t e_shnum;
    uint16_t e_shstrndx;
};

struct Elf32_Phdr {
    uint32_t p_type;
    uint32_t p_offset;
    uint32_t p_vaddr;
    uint32_t p_paddr;
    uint32_t p_filesz;
    uint32_t p_memsz;
    uint32_t p_flags;
    uint32_t p_align;
};

struct Elf32_Shdr {
    uint32_t sh_name;
    uint32_t sh_type;
    uint32_t sh_flags;
    uint32_t sh_addr;
    uint32_t sh_offset;
    uint32_t sh_size;
    uint32_t sh_link;
    uint32_t sh_info;
    uint32_t sh_addralign;
    uint32_t sh_entsize;
};

struct Elf32_Sym {
    uint32_t st_name;
    uint32_t st_value;
    uint32_t st_size;
    unsigned char st_info;
    unsigned char st_other;
    uint16_t st_shndx;
};

// ELF constants
#define PT_LOAD 1
#define SHT_SYMTAB 2
#define SHT_STRTAB 3
#define SHT_DYNSYM 11

// Load ELF file into DUT's internal memory
bool load_elf(void* dut, const std::string& filename) {
    FILE* f = fopen(filename.c_str(), "rb");
    if (!f) {
        fprintf(stderr, "ERROR: Cannot open ELF file: %s\n", filename.c_str());
        fprintf(stderr, "       Please check that the file exists and is readable.\n");
        return false;
    }

    // Read ELF header
    Elf32_Ehdr ehdr;
    if (fread(&ehdr, sizeof(ehdr), 1, f) != 1) {
        fprintf(stderr, "ERROR: Failed to read ELF header from %s\n", filename.c_str());
        fprintf(stderr, "       File may be truncated or corrupted.\n");
        fclose(f);
        return false;
    }

    // Check ELF magic number
    if (ehdr.e_ident[0] != 0x7f || ehdr.e_ident[1] != 'E' ||
        ehdr.e_ident[2] != 'L' || ehdr.e_ident[3] != 'F') {
        fprintf(stderr, "ERROR: Not a valid ELF file: %s\n", filename.c_str());
        fprintf(stderr, "       File format is not recognized as ELF.\n");
        fclose(f);
        return false;
    }

    printf("Loading ELF file: %s\n", filename.c_str());
    printf("Entry point: 0x%08x\n", ehdr.e_entry);

    // Set the scope for DPI calls to the memory module
    svSetScope(svGetScopeFromName("TOP.tb_kv32_soc.ext_mem"));

    // Load program headers (segments)
    size_t total_bytes = 0;
    for (int i = 0; i < ehdr.e_phnum; i++) {
        // Seek to program header
        fseek(f, ehdr.e_phoff + i * ehdr.e_phentsize, SEEK_SET);

        Elf32_Phdr phdr;
        if (fread(&phdr, sizeof(phdr), 1, f) != 1) {
            fprintf(stderr, "Failed to read program header %d\n", i);
            continue;
        }

        // Only load PT_LOAD segments
        if (phdr.p_type != PT_LOAD) {
            continue;
        }

        // Seek to segment data
        fseek(f, phdr.p_offset, SEEK_SET);

        // Read and write segment data to memory
        for (uint32_t j = 0; j < phdr.p_filesz; j++) {
            int byte_val = fgetc(f);
            if (byte_val == EOF) {
                fprintf(stderr, "Unexpected EOF reading segment data\n");
                break;
            }
            uint32_t addr = phdr.p_paddr - g_mem_base + j;
            mem_write_byte(addr, (char)byte_val);
            total_bytes++;
        }

        // Zero-initialize BSS (memsz > filesz)
        for (uint32_t j = phdr.p_filesz; j < phdr.p_memsz; j++) {
            uint32_t addr = phdr.p_paddr - g_mem_base + j;
            mem_write_byte(addr, 0);
            total_bytes++;
        }
    }

    printf("Loaded %zu bytes from ELF segments\n", total_bytes);

    // Parse symbol table
    for (int i = 0; i < ehdr.e_shnum; i++) {
        // Seek to section header
        fseek(f, ehdr.e_shoff + i * ehdr.e_shentsize, SEEK_SET);

        Elf32_Shdr shdr;
        if (fread(&shdr, sizeof(shdr), 1, f) != 1) {
            continue;
        }

        // Look for symbol table sections
        if (shdr.sh_type != SHT_SYMTAB && shdr.sh_type != SHT_DYNSYM) {
            continue;
        }

        // Get the associated string table section
        fseek(f, ehdr.e_shoff + shdr.sh_link * ehdr.e_shentsize, SEEK_SET);
        Elf32_Shdr strtab_shdr;
        if (fread(&strtab_shdr, sizeof(strtab_shdr), 1, f) != 1) {
            continue;
        }

        // Read string table
        fseek(f, strtab_shdr.sh_offset, SEEK_SET);
        char* strtab = (char*)malloc(strtab_shdr.sh_size);
        if (!strtab || fread(strtab, 1, strtab_shdr.sh_size, f) != strtab_shdr.sh_size) {
            free(strtab);
            continue;
        }

        // Read symbol table
        size_t num_symbols = shdr.sh_size / shdr.sh_entsize;
        fseek(f, shdr.sh_offset, SEEK_SET);

        for (size_t j = 0; j < num_symbols; j++) {
            Elf32_Sym sym;
            if (fread(&sym, sizeof(sym), 1, f) != 1) {
                break;
            }

            // Get symbol name
            if (sym.st_name == 0 || sym.st_name >= strtab_shdr.sh_size) {
                continue;
            }

            const char* name = &strtab[sym.st_name];

            // Store symbol
            Symbol symbol;
            symbol.name = name;
            symbol.addr = sym.st_value;
            symbol.size = sym.st_size;
            g_symbols[name] = symbol;

            // Check for special symbols
            if (strcmp(name, "tohost") == 0) {
                g_tohost_addr = sym.st_value;
                printf("Found symbol 'tohost' at address 0x%08x\n", g_tohost_addr);
            } else if (strcmp(name, "fromhost") == 0) {
                g_fromhost_addr = sym.st_value;
                printf("Found symbol 'fromhost' at address 0x%08x\n", g_fromhost_addr);
            }
        }

        free(strtab);
    }

    printf("Parsed %zu symbols from ELF file\n", g_symbols.size());

    fclose(f);
    return true;
}

// Load binary file into DUT's internal memory (legacy support)
bool load_bin(void* dut, const std::string& filename) {
    FILE* f = fopen(filename.c_str(), "rb");
    if (!f) {
        fprintf(stderr, "ERROR: Cannot open binary file: %s\n", filename.c_str());
        fprintf(stderr, "       Please check that the file exists and is readable.\n");
        return false;
    }

    // Set the scope for DPI calls to the memory module
    svSetScope(svGetScopeFromName("TOP.tb_kv32_soc.ext_mem"));

    // Read file and write to memory via DPI-C
    int addr = 0;
    int byte_val;
    size_t bytes_read = 0;

    while ((byte_val = fgetc(f)) != EOF) {
        mem_write_byte(addr, (char)byte_val);
        addr++;
        bytes_read++;
    }

    fclose(f);
    printf("Loaded %zu bytes from %s\n", bytes_read, filename.c_str());
    return true;
}

// Auto-detect and load program (ELF or binary)
bool load_program(void* dut, const std::string& filename) {
    // Check if file exists and read magic number
    FILE* f = fopen(filename.c_str(), "rb");
    if (!f) {
        fprintf(stderr, "ERROR: Cannot open program file: %s\n", filename.c_str());
        fprintf(stderr, "       Please check that the file exists and is readable.\n");
        return false;
    }

    // Check for ELF magic number (0x7f 'E' 'L' 'F')
    unsigned char magic[4];
    size_t read_count = fread(magic, 1, 4, f);
    fclose(f);

    if (read_count == 4 && magic[0] == 0x7f && magic[1] == 'E' &&
        magic[2] == 'L' && magic[3] == 'F') {
        // It's an ELF file
        return load_elf(dut, filename);
    } else {
        // Assume it's a binary file
        return load_bin(dut, filename);
    }
}
