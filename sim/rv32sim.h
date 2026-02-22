// RISC-V RV32IMAC Functional Simulator - Header
// Contains ELF definitions, magic addresses, and device classes

#ifndef RV32SIM_H
#define RV32SIM_H

#include <stdint.h>
#include <vector>
#include <fstream>
#include <cstring>
#include <string>
#include "device.h"

// Lightweight ELF definitions (ELF32)
#define EI_NIDENT 16
#define ELFMAG "\177ELF"
#define SELFMAG 4

// ELF header
struct Elf32_Ehdr {
    uint8_t  e_ident[EI_NIDENT];
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

// Program header
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

// Section header
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

// Symbol table entry
struct Elf32_Sym {
    uint32_t st_name;
    uint32_t st_value;
    uint32_t st_size;
    uint8_t  st_info;
    uint8_t  st_other;
    uint16_t st_shndx;
};

// ELF constants
#define PT_LOAD    1
#define SHT_SYMTAB 2
#define SHT_STRTAB 3

// GDB stub default port
#define GDB_DEFAULT_PORT   3333        // Default GDB remote debugging port

// CSR addresses
#define CSR_MSTATUS   0x300
#define CSR_MISA      0x301
#define CSR_MIE       0x304
#define CSR_MTVEC     0x305
#define CSR_MSCRATCH  0x340
#define CSR_MEPC      0x341
#define CSR_MCAUSE    0x342
#define CSR_MTVAL     0x343
#define CSR_MIP       0x344

// Machine Counter/Timers (writable in M-mode)
#define CSR_MCYCLE    0xb00  // Machine cycle counter (lower 32 bits)
#define CSR_MINSTRET  0xb02  // Machine instructions retired (lower 32 bits)
#define CSR_MCYCLEH   0xb80  // Machine cycle counter (upper 32 bits)
#define CSR_MINSTRETH 0xb82  // Machine instructions retired (upper 32 bits)

// User-level CSRs (read-only counters)
#define CSR_CYCLE     0xc00  // Cycle counter (alias to mcycle)
#define CSR_TIME      0xc01  // Timer (alias to mcycle)
#define CSR_INSTRET   0xc02  // Instructions retired (alias to minstret)
#define CSR_CYCLEH    0xc80  // Cycle counter high
#define CSR_TIMEH     0xc81  // Timer high
#define CSR_INSTRETH  0xc82  // Instructions retired high

// Machine information CSRs (read-only)
#define CSR_MVENDORID 0xf11  // Vendor ID
#define CSR_MARCHID   0xf12  // Architecture ID
#define CSR_MIMPID    0xf13  // Implementation ID
#define CSR_MHARTID   0xf14  // Hart ID

// Exception/Interrupt codes
#define CAUSE_MISALIGNED_FETCH    0
#define CAUSE_FETCH_ACCESS        1
#define CAUSE_ILLEGAL_INSTRUCTION 2
#define CAUSE_BREAKPOINT          3
#define CAUSE_MISALIGNED_LOAD     4
#define CAUSE_LOAD_ACCESS         5
#define CAUSE_MISALIGNED_STORE    6
#define CAUSE_STORE_ACCESS        7
#define CAUSE_ECALL_FROM_M        11
#define CAUSE_MACHINE_TIMER_INT   0x80000007
#define CAUSE_MACHINE_SOFTWARE_INT 0x80000003

// RV32IMAC CPU simulator
class RV32Simulator {
public:
    struct SlaveRegion {
        uint32_t base;
        uint32_t size;
        Device* device;
        std::string name;
    };

    uint32_t regs[32];
    uint32_t pc;
    MemoryDevice* memory;
    bool running;
    int exit_code;
    uint64_t inst_count;

    // Device drivers
    std::vector<SlaveRegion> slaves;  // Universal slave interface table
    MagicDevice* magic;
    UARTDevice* uart;
    SPIDevice* spi;
    I2CDevice* i2c;
    CLINTDevice* clint;

    uint32_t tohost_addr;
    std::ofstream trace_file;
    bool trace_enabled;
    bool rtl_trace_format;  // If true, use RTL trace format instead of Spike format
    uint32_t mem_base;
    uint32_t mem_size;

    // GDB stub support
    void* gdb_ctx;
    bool gdb_enabled;
    bool gdb_stepping;

    // Instruction limit (0 = no limit)
    uint64_t max_instructions;

    // Signature support (for RISCV arch tests)
    std::string signature_file;
    uint32_t signature_start;
    uint32_t signature_end;
    uint32_t signature_granularity;
    bool signature_enabled;

    // CSR registers
    uint32_t csr_mstatus;
    uint32_t csr_misa;
    uint32_t csr_mie;
    uint32_t csr_mtvec;
    uint32_t csr_mscratch;
    uint32_t csr_mepc;
    uint32_t csr_mcause;
    uint32_t csr_mtval;
    uint32_t csr_mip;

    // Machine-level counters (writable in M-mode)
    uint64_t csr_mcycle;    // 64-bit cycle counter
    uint64_t csr_minstret;  // 64-bit instruction counter

    // Machine information registers (read-only)
    uint32_t csr_mvendorid;  // Vendor ID
    uint32_t csr_marchid;    // Architecture ID
    uint32_t csr_mimpid;     // Implementation ID
    uint32_t csr_mhartid;    // Hart ID (hardware thread)

    // Exception handling
    bool exception_occurred;
    uint32_t exception_pc;

    RV32Simulator(uint32_t base = MEM_BASE, uint32_t size = MEM_SIZE);
    ~RV32Simulator();

    void enable_trace(const char* filename, bool rtl_format = false);
    void enable_signature(const char* filename, uint32_t granularity = 4);
    void write_signature();
    void log_commit(uint32_t pc, uint32_t inst, int rd_num, uint32_t rd_val, bool has_mem, uint32_t mem_addr, uint32_t mem_val, bool is_store, bool is_csr, uint32_t csr_num);

    // Universal memory/slave interface helpers
    void register_device_slave(uint32_t base, uint32_t size, Device* device, const char* name);
    // Undo a tick for all registered slave devices (used when exception fires)
    void untick_slaves();
    const SlaveRegion* find_slave(uint32_t addr) const;
    uint32_t bus_read(uint32_t addr, int size, bool* handled = nullptr);
    bool bus_write(uint32_t addr, uint32_t value, int size);
    void tick_slaves();

    uint32_t read_mem(uint32_t addr, int size);
    void write_mem(uint32_t addr, uint32_t value, int size);
    int32_t sign_extend(uint32_t value, int bits);

    // CSR operations
    uint32_t read_csr(uint32_t csr);
    void write_csr(uint32_t csr, uint32_t value);

    // Interrupt and exception handling
    void take_trap(uint32_t cause, uint32_t tval);
    void check_interrupts();

    void step();
    bool load_elf(const char* filename);
    void run();
};

#endif // RV32SIM_H
