/**
 * @file kv32sim.h
 * @brief RV32IMAC functional simulator — ELF types, CSR constants, and KV32Simulator class.
 *
 * Declares the KV32Simulator class used by kv32sim.cpp and the RTL testbench
 * (tb_kv32_soc.cpp) as the golden-reference software model.
 * @defgroup simulator Simulator API
 * @{
 */
// RISC-V RV32IMAC Functional Simulator - Header
// Contains ELF definitions, magic addresses, and device classes

#ifndef KV32SIM_H
#define KV32SIM_H

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

// Custom M-mode PMA CSRs (0x7C0-0x7CB)
#define CSR_PMACFG0   0x7C0  // Packed PMA cfg bytes for regions 0-3
#define CSR_PMACFG1   0x7C1  // Packed PMA cfg bytes for regions 4-7
#define CSR_PMAADDR0  0x7C4  // physaddr>>2 for PMA region 0
#define CSR_PMAADDR1  0x7C5  // physaddr>>2 for PMA region 1
#define CSR_PMAADDR2  0x7C6  // physaddr>>2 for PMA region 2
#define CSR_PMAADDR3  0x7C7  // physaddr>>2 for PMA region 3
#define CSR_PMAADDR4  0x7C8  // physaddr>>2 for PMA region 4
#define CSR_PMAADDR5  0x7C9  // physaddr>>2 for PMA region 5
#define CSR_PMAADDR6  0x7CA  // physaddr>>2 for PMA region 6
#define CSR_PMAADDR7  0x7CB  // physaddr>>2 for PMA region 7
#define CSR_SGUARD_BASE 0x7CC
#define CSR_SPMIN       0x7CD
#define CSR_ICAP        0x7D0
#define CSR_DCAP        0x7D1
#define CSR_CDIAG_CMD   0x7D2
#define CSR_CDIAG_TAG   0x7D3
#define CSR_CDIAG_DATA  0x7D4

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
#define CAUSE_STACK_OVERFLOW      16
#define CAUSE_MACHINE_TIMER_INT    0x80000007
#define CAUSE_MACHINE_SOFTWARE_INT 0x80000003
#define CAUSE_MACHINE_EXTERNAL_INT 0x8000000B  // MEIP (bit 11)

// RV32IMAC CPU simulator
/**
 * @brief RV32IMAC functional simulator implementing the full instruction set,
 *        memory-mapped peripherals, CSRs, and optional GDB remote debugging.
 *
 * KV32Simulator is the golden-reference software model used to validate the
 * RTL implementation via trace comparison.  It exposes the same AXI slave
 * address map as kv32_soc.sv and provides instruction-accurate execution
 * including precise exception semantics.
 *
 * @note Instantiated in kv32sim.cpp (standalone) and tb_kv32_soc.cpp (co-sim).
 */
class KV32Simulator {
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
    uint64_t trap_count = 0;       // total traps taken; useful for debugging

    // WFI / irq_was_pending simulation
    // Mirrors the RTL sticky flag: set when an interrupt fires outside the WFI
    // spin loop (i.e. the ISR ran to completion before WFI was dispatched);
    // cleared when WFI consumes it (NOP-exit).  wfi_spin_active prevents normal
    // ISR-wakeup paths from setting the flag.
    bool wfi_spin_active       = false;  // true while inside the WFI spin loop
    bool irq_before_wfi        = false;  // interrupt handled before WFI reached spin
    // wfi_recently_completed: set when WFI wakes via its spin loop (normal path).
    // While this is true, cascaded interrupts that fire after MRET (e.g. MSIP
    // cascaded from a timer ISR) are recognised as part of the same WFI wakeup
    // event and must NOT set irq_before_wfi.  Cleared on the first clean
    // user-mode step (MIE=1, no interrupt taken) after all cascades settle.
    bool wfi_recently_completed = false;

    // Device drivers
    std::vector<SlaveRegion> slaves;  // Universal slave interface table
    MagicDevice* magic;
    UARTDevice* uart;
    SPIDevice* spi;
    I2CDevice* i2c;
    CLINTDevice* clint;
    PLICDevice* plic;
    DMADevice* dma;
    GPIODevice* gpio;
    TimerDevice* timer;
    WatchdogDevice* wdt;

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

    // Custom M-mode PMA CSRs
    uint32_t csr_pmacfg[2];   // pmacfg0 (regions 0-3), pmacfg1 (regions 4-7)
    uint32_t csr_pmaaddr[8];  // pmaaddr0-7
    uint32_t csr_sguard_base;
    uint32_t csr_spmin;
    uint32_t csr_cdiag_cmd;

    // Exception handling
    bool exception_occurred;
    uint32_t exception_pc;
    bool last_bus_error;  // Set by bus_read/bus_write when device signals SLVERR

    KV32Simulator(uint32_t base = MEM_BASE, uint32_t size = MEM_SIZE);
    ~KV32Simulator();

    /** @brief Enable instruction trace output.
     * @param filename Output file path.
     * @param rtl_format If true, emit RTL-compatible trace format (default: Spike format). */
    void enable_trace(const char* filename, bool rtl_format = false);
    /** @brief Enable reference-signature capture (RISC-V arch-test).
     * @param filename Output file path for the signature file.
     * @param granularity Bytes per signature word (default 4). */
    void enable_signature(const char* filename, uint32_t granularity = 4);
    /** @brief Write the captured signature to the file. */
    void write_signature();
    void log_commit(uint32_t pc, uint32_t inst, int rd_num, uint32_t rd_val, bool has_mem, uint32_t mem_addr, uint32_t mem_val, bool is_store, bool is_csr, uint32_t csr_num);

    // Universal memory/slave interface helpers
    /** @brief Register an AXI slave device.
     * @param base Base address.
     * @param size Address window size in bytes.
     * @param device Pointer to device object.
     * @param name Human-readable name for debug output. */
    void register_device_slave(uint32_t base, uint32_t size, Device* device, const char* name);
    /** @brief Undo a tick for all registered slave devices (used when exception fires). */
    void untick_slaves();
    /** @brief Find the slave region covering @p addr, or nullptr. */
    const SlaveRegion* find_slave(uint32_t addr) const;
    /** @brief Perform a bus read; sets device::last_bus_error on SLVERR.
     * @param addr Physical address.
     * @param size Transfer size in bytes (1/2/4).
     * @param handled Optional output set to true if a slave responded.
     * @return Data word (zero-extended). */
    uint32_t bus_read(uint32_t addr, int size, bool* handled = nullptr);
    /** @brief Perform a bus write.
     * @param addr Physical address.
     * @param value Data to write.
     * @param size Transfer size in bytes (1/2/4).
     * @return true if a slave accepted the transaction. */
    bool bus_write(uint32_t addr, uint32_t value, int size);
    /** @brief Tick all registered slave devices by one cycle. */
    void tick_slaves();

    /** @brief Read a physical memory address.
     * @param addr Address.
     * @param size Bytes (1/2/4).
     * @param is_fetch True for instruction fetches (affects exception type). */
    uint32_t read_mem(uint32_t addr, int size, bool is_fetch = false);
    /** @brief Write a physical memory address. */
    void write_mem(uint32_t addr, uint32_t value, int size);
    /** @brief Sign-extend @p value from @p bits to 32 bits. */
    int32_t sign_extend(uint32_t value, int bits);

    // CSR operations
    /** @brief Read a CSR by address. @param csr CSR address (12-bit). @return CSR value. */
    uint32_t read_csr(uint32_t csr);
    /** @brief Write a CSR by address. @param csr CSR address. @param value New value. */
    void write_csr(uint32_t csr, uint32_t value);

    // Interrupt and exception handling
    /** @brief Deliver a synchronous or asynchronous trap.
     * @param cause mcause value (bit 31 set for interrupts).
     * @param tval mtval value (faulting address or instruction). */
    void take_trap(uint32_t cause, uint32_t tval);
    /** @brief Check and deliver any pending interrupts. */
    void check_interrupts();

    /** @brief Execute a single instruction (advance PC by one step). */
    void step();
    /** @brief Load an ELF32 binary into the simulator memory.
     * @param filename Path to the ELF file.
     * @return true on success. */
    bool load_elf(const char* filename);
    /** @brief Run the simulator until exit or instruction limit. */
    void run();
};

/** @} */ /* end group simulator */

#endif // KV32SIM_H
