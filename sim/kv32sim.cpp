// RISC-V RV32IMAC Functional Simulator
// Software simulator with UART, console magic address, and exit support
// Implements basic RV32IMAC instruction set with special device handling

#include "kv32sim.h"
#include "riscv-dis.h"
#include "gdb_stub.h"
#include "device.h"
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <stdint.h>
#include <string>
#include <unordered_set>
#include <vector>
#include <unistd.h>
#include <cctype>
#include <csignal>
#include <cstdio>
#include <csignal>
#include <cstdio>

// SIGINT handler support
static volatile sig_atomic_t sigint_received = 0;
static KV32Simulator* g_sim_instance = nullptr;

static void handle_sigint(int) {
    sigint_received = 1;
}

// Helper function to get register name
static const char* get_reg_name(uint32_t reg) {
    static const char* names[] = {
        "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
        "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
        "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
        "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"
    };
    if (reg < 32) return names[reg];
    return "unknown";
}

static void dump_registers(KV32Simulator* sim) {
    std::cout << "\n=== Register Dump (SIGINT) ===" << std::endl;
    std::cout << "PC  : 0x" << std::hex << std::setfill('0') << std::setw(8) << sim->pc << std::dec << std::endl;

    for (uint32_t i = 0; i < 32; i += 4) {
        char line[160];
        uint32_t r0 = i + 0;
        uint32_t r1 = i + 1;
        uint32_t r2 = i + 2;
        uint32_t r3 = i + 3;
        std::snprintf(
            line,
            sizeof(line),
            "%4s: 0x%08x    %4s: 0x%08x    %4s: 0x%08x    %4s: 0x%08x",
            get_reg_name(r0), sim->regs[r0],
            get_reg_name(r1), sim->regs[r1],
            get_reg_name(r2), sim->regs[r2],
            get_reg_name(r3), sim->regs[r3]
        );
        std::cout << line << std::endl;
    }
    std::cout << "==============================\n" << std::endl;
}

// GDB stub callback functions
static uint32_t gdb_read_reg(void* user_data, int regno) {
    KV32Simulator* sim = (KV32Simulator*)user_data;
    if (regno >= 0 && regno < 32) {
        return sim->regs[regno];
    } else if (regno == 32) { // PC
        return sim->pc;
    }
    return 0;
}

static void gdb_write_reg(void* user_data, int regno, uint32_t value) {
    KV32Simulator* sim = (KV32Simulator*)user_data;
    if (regno >= 0 && regno < 32) {
        sim->regs[regno] = value;
        if (regno == 0) sim->regs[0] = 0; // x0 is always 0
    } else if (regno == 32) { // PC
        sim->pc = value;
    }
}

static uint32_t gdb_read_mem(void* user_data, uint32_t addr, int size) {
    KV32Simulator* sim = (KV32Simulator*)user_data;
    bool handled = false;
    return sim->bus_read(addr, size, &handled);
}

static void gdb_write_mem(void* user_data, uint32_t addr, uint32_t value, int size) {
    KV32Simulator* sim = (KV32Simulator*)user_data;
    sim->bus_write(addr, value, size);
}

static uint32_t gdb_get_pc(void* user_data) {
    KV32Simulator* sim = (KV32Simulator*)user_data;
    return sim->pc;
}

static void gdb_set_pc(void* user_data, uint32_t pc) {
    KV32Simulator* sim = (KV32Simulator*)user_data;
    sim->pc = pc;
}

static void gdb_single_step(void* user_data) {
    KV32Simulator* sim = (KV32Simulator*)user_data;
    sim->gdb_stepping = true;
    sim->step();
    sim->gdb_stepping = false;
}

static bool gdb_is_running(void* user_data) {
    KV32Simulator* sim = (KV32Simulator*)user_data;
    return sim->running;
}

// RV32IMAC CPU simulator implementation
KV32Simulator::KV32Simulator(uint32_t base, uint32_t size)
    : pc(0), running(true), exit_code(0), inst_count(0), tohost_addr(0),
      trace_enabled(false), mem_base(base), mem_size(size), gdb_ctx(nullptr),
      gdb_enabled(false), gdb_stepping(false), max_instructions(0),
      signature_start(0), signature_end(0), signature_granularity(4),
      signature_enabled(false), exception_occurred(false), exception_pc(0),
      last_bus_error(false) {
        memory = new MemoryDevice(mem_size);
    memset(regs, 0, sizeof(regs));
    regs[0] = 0; // x0 is always 0

    // Initialize CSRs
    csr_mstatus = 0x00000000; // Start with cleared mstatus (spike behavior)
    csr_misa = 0x40141101;    // RV32IMASU default (no C); overridden by compute_misa() in main()
    csr_mie = 0;
    csr_mtvec = 0;
    csr_mscratch = 0;
    csr_mepc = 0;
    csr_mcause = 0;
    csr_mtval = 0;
    csr_mip = 0;

    // Initialize counters
    csr_mcycle = 0;
    csr_minstret = 0;

    // Initialize machine information registers
    csr_mvendorid = 0;  // No vendor ID
    csr_marchid = 0;    // No architecture ID
    csr_mimpid = 0;     // No implementation ID
    csr_mhartid = 0;    // Hart ID = 0 (single core)

    // Initialize device drivers
    magic = new MagicDevice();
    uart = new UARTDevice();
    spi = new SPIDevice();
    i2c = new I2CDevice();
    clint = new CLINTDevice();
    plic = new PLICDevice();
    dma = new DMADevice(
        [this](uint32_t addr, int sz) {
            bool handled = false;
            return bus_read(addr, sz, &handled);
        },
        [this](uint32_t addr, uint32_t val, int sz) {
            bus_write(addr, val, sz);
        }
    );
    gpio = new GPIODevice();
    timer = new TimerDevice();

    // Register universal slave interface windows
    register_device_slave(mem_base, mem_size, memory, "RAM");
    register_device_slave(CLINT_BASE, CLINT_SIZE, clint, "CLINT");
    register_device_slave(PLIC_BASE, PLIC_SIZE, plic, "PLIC");
    register_device_slave(UART_BASE, UART_SIZE, uart, "UART");
    register_device_slave(SPI_BASE, SPI_SIZE, spi, "SPI");
    register_device_slave(I2C_BASE, I2C_SIZE, i2c, "I2C");
    register_device_slave(MAGIC_BASE, MAGIC_SIZE, magic, "MAGIC");
    register_device_slave(KV_DMA_BASE, KV_DMA_SIZE, dma, "DMA");
    register_device_slave(GPIO_BASE, GPIO_SIZE, gpio, "GPIO");
    register_device_slave(TIMER_BASE, TIMER_SIZE, timer, "TIMER");
}

KV32Simulator::~KV32Simulator() {
    // Clean up devices
    delete magic;
    delete uart;
    delete spi;
    delete i2c;
    delete clint;
    delete plic;
    delete dma;
    delete gpio;
    delete timer;
    slaves.clear();

    delete memory;
    if (trace_file.is_open()) {
        trace_file.close();
    }
}

void KV32Simulator::enable_trace(const char *filename, bool rtl_format) {
    trace_enabled = true;
    rtl_trace_format = rtl_format;
    trace_file.open(filename);
    if (!trace_file.is_open()) {
        std::cerr << "Warning: Failed to open trace file: " << filename
                  << std::endl;
        trace_enabled = false;
    }
}

void KV32Simulator::enable_signature(const char *filename, uint32_t granularity) {
    signature_file = filename;
    signature_granularity = granularity;
    signature_enabled = true;
}

void KV32Simulator::write_signature() {
    if (!signature_enabled || signature_start == 0 || signature_end == 0) {
        return;
    }

    std::ofstream sig_file(signature_file);
    if (!sig_file.is_open()) {
        std::cerr << "Error: Failed to open signature file: " << signature_file << std::endl;
        return;
    }

    // Write signature data in hex format
    for (uint32_t addr = signature_start; addr < signature_end; addr += signature_granularity) {
        if (addr + signature_granularity > signature_end) {
            break;
        }
        uint32_t value = read_mem(addr, signature_granularity);
        sig_file << std::hex << std::setfill('0') << std::setw(signature_granularity * 2) << value << std::endl;
    }

    sig_file.close();
}

void KV32Simulator::log_commit(uint32_t pc, uint32_t inst, int rd_num,
                               uint32_t rd_val, bool has_mem,
                               uint32_t mem_addr, uint32_t mem_val,
                               bool is_store, bool is_csr,
                               uint32_t csr_num) {
    if (!trace_enabled || !trace_file.is_open()) {
        return;
    }

    static RiscvDisassembler disassembler;

    if (rtl_trace_format) {
        // RTL trace format: CYCLES PC (INSTR) [reg_write] [mem] [csr] ; disasm
        std::ostringstream line_stream;

        // Cycle count (use instruction count as proxy), PC, and instruction encoding
        line_stream << std::dec << inst_count << " "
                   << "0x" << std::hex << std::setfill('0') << std::setw(8) << pc << " "
                   << "(0x" << std::setw(8) << inst << ")";

        // Get register names mapping
        static const char* reg_names[] = {
            "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
            "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
            "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
            "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"
        };

        // Add register write if present (skip if CSR write is present)
        if (rd_num > 0 && !is_csr) {
            line_stream << " " << reg_names[rd_num] << " "
                       << "0x" << std::hex << std::setfill('0') << std::setw(8) << rd_val;
        }

        // Add memory operation if present
        if (has_mem) {
            line_stream << " mem 0x" << std::hex << std::setfill('0') << std::setw(8) << mem_addr;
            if (is_store) {
                line_stream << " 0x" << std::setw(8) << mem_val;
            }
        }

        // Add CSR operation if present (matches RTL format: c<addr>_<name> <value>)
        if (is_csr) {
            const char *csr_name = "";
            switch (csr_num) {
            case 0x300: csr_name = "mstatus"; break;
            case 0x301: csr_name = "misa"; break;
            case 0x304: csr_name = "mie"; break;
            case 0x305: csr_name = "mtvec"; break;
            case 0x340: csr_name = "mscratch"; break;
            case 0x341: csr_name = "mepc"; break;
            case 0x342: csr_name = "mcause"; break;
            case 0x343: csr_name = "mtval"; break;
            case 0x344: csr_name = "mip"; break;
            case 0xb00: csr_name = "mcycle"; break;
            case 0xb02: csr_name = "minstret"; break;
            case 0xc00: csr_name = "cycle"; break;
            case 0xc01: csr_name = "time"; break;
            case 0xc02: csr_name = "instret"; break;
            default: csr_name = "unknown"; break;
            }
            line_stream << " c" << std::setfill('0') << std::setw(3) << std::hex << csr_num
                       << "_" << csr_name
                       << " 0x" << std::setw(8) << rd_val;
        }

        // Get base line for alignment
        std::string base_line = line_stream.str();

        // Add disassembly comment aligned at column 72
        std::string disasm = disassembler.disassemble(inst, pc);
        int padding_needed = 72 - base_line.length();
        if (padding_needed < 2) padding_needed = 2;  // At least 2 spaces

        trace_file << base_line << std::string(padding_needed, ' ') << "; " << disasm << std::endl;

    } else {
        // Spike trace format: core   0: 3 0xPC (0xINSTR) x<rd> 0x<value> [mem/csr]
        trace_file << "core   0: 3 0x" << std::hex << std::setfill('0')
                   << std::setw(8) << pc << " (0x" << std::setw(8) << inst
                   << ")";

        // Log register write (skip if CSR write is present)
        if (rd_num > 0 && !is_csr) {
            trace_file << " x" << std::dec << std::left << std::setfill(' ')
                       << std::setw(2) << rd_num << " 0x" << std::right
                       << std::hex << std::setfill('0') << std::setw(8)
                       << rd_val;
        }

        // Log CSR write
        if (is_csr) {
            const char *csr_name = "";
            switch (csr_num) {
            case 0x300: csr_name = "mstatus"; break;
            case 0x301: csr_name = "misa"; break;
            case 0x304: csr_name = "mie"; break;
            case 0x305: csr_name = "mtvec"; break;
            case 0x340: csr_name = "mscratch"; break;
            case 0x341: csr_name = "mepc"; break;
            case 0x342: csr_name = "mcause"; break;
            case 0x343: csr_name = "mtval"; break;
            case 0x344: csr_name = "mip"; break;
            default: csr_name = "unknown"; break;
            }
            trace_file << " c" << std::dec << csr_num << "_" << csr_name
                       << " 0x" << std::hex << std::setfill('0') << std::setw(8)
                       << rd_val;
        }

        // Log memory access
        if (has_mem) {
            trace_file << " mem 0x" << std::hex << std::setfill('0')
                       << std::setw(8) << mem_addr;
            // Only show memory value for stores (loads show value in register)
            if (is_store) {
                trace_file << " 0x" << std::setw(8) << mem_val;
            }
        }

        trace_file << std::endl;
    }
}

// CSR operations
uint32_t KV32Simulator::read_csr(uint32_t csr) {
    switch (csr) {
    case CSR_MSTATUS:
        return csr_mstatus;
    case CSR_MISA:
        return csr_misa;
    case CSR_MIE:
        return csr_mie;
    case CSR_MTVEC:
        return csr_mtvec;
    case CSR_MSCRATCH:
        return csr_mscratch;
    case CSR_MEPC:
        return csr_mepc;
    case CSR_MCAUSE:
        return csr_mcause;
    case CSR_MTVAL:
        return csr_mtval;
    case CSR_MIP:
        return csr_mip;

    // Machine-mode counters (writable)
    //
    // Trace-compare mode note (--rtl-trace):
    //   In the software simulator every instruction increments BOTH csr_mcycle and
    //   csr_minstret by exactly 1, so they are always equal.  The RTL, however,
    //   increments mcycle every clock cycle (CPI > 1 due to pipeline stalls) while
    //   minstret only increments on instruction retirement.
    //
    //   When --rtl-trace is active the RTL core is told to return minstret instead
    //   of mcycle for cycle/time CSR reads (via the trace_mode signal), making the
    //   RTL counter pipeline-stall-independent and equal to the simulator value.
    //   Here we do the same explicitly: return csr_minstret for cycle/time reads
    //   so the behaviour is symmetric and the comment is self-documenting.
    //   (The result is numerically identical since csr_mcycle == csr_minstret here.)
    case CSR_MCYCLE:
        return rtl_trace_format ? (uint32_t)(csr_minstret & 0xFFFFFFFF)
                                : (uint32_t)(csr_mcycle   & 0xFFFFFFFF);
    case CSR_MCYCLEH:
        return rtl_trace_format ? (uint32_t)(csr_minstret >> 32)
                                : (uint32_t)(csr_mcycle   >> 32);
    case CSR_MINSTRET:
        return (uint32_t)(csr_minstret & 0xFFFFFFFF);
    case CSR_MINSTRETH:
        return (uint32_t)(csr_minstret >> 32);

    // User-level counters (read-only, aliased to machine-mode counters)
    case CSR_CYCLE:
        return rtl_trace_format ? (uint32_t)(csr_minstret & 0xFFFFFFFF)
                                : (uint32_t)(csr_mcycle   & 0xFFFFFFFF);
    case CSR_CYCLEH:
        return rtl_trace_format ? (uint32_t)(csr_minstret >> 32)
                                : (uint32_t)(csr_mcycle   >> 32);
    case CSR_TIME:
        return rtl_trace_format ? (uint32_t)(csr_minstret & 0xFFFFFFFF)
                                : (uint32_t)(csr_mcycle   & 0xFFFFFFFF);  // Alias to cycle
    case CSR_TIMEH:
        return rtl_trace_format ? (uint32_t)(csr_minstret >> 32)
                                : (uint32_t)(csr_mcycle   >> 32);
    case CSR_INSTRET:
        return (uint32_t)(csr_minstret & 0xFFFFFFFF);
    case CSR_INSTRETH:
        return (uint32_t)(csr_minstret >> 32);

    // Machine information registers (read-only)
    case CSR_MVENDORID:
        return csr_mvendorid;
    case CSR_MARCHID:
        return csr_marchid;
    case CSR_MIMPID:
        return csr_mimpid;
    case CSR_MHARTID:
        return csr_mhartid;
    default:
        std::cerr << "Warning: Reading unknown CSR 0x" << std::hex << csr
                  << std::endl;
        return 0;
    }
}

void KV32Simulator::write_csr(uint32_t csr, uint32_t value) {
    switch (csr) {
    case CSR_MSTATUS:
        csr_mstatus = value & 0x00001888;
        break;     // Only writable bits
    case CSR_MIE:
        csr_mie = value & 0x888;
        break;
    case CSR_MTVEC:
        csr_mtvec = value;
        break;
    case CSR_MSCRATCH:
        csr_mscratch = value;
        break;
    case CSR_MEPC:
        csr_mepc = value & ~1u;  // RVC: 2-byte aligned; non-RVC would be ~3u
        break;
    case CSR_MCAUSE:
        csr_mcause = value;
        break;
    case CSR_MTVAL:
        csr_mtval = value;
        break;
    case CSR_MIP:
        csr_mip = value & 0x888;
        break;

    // Machine-mode counters (writable in M-mode)
    case CSR_MCYCLE:
        csr_mcycle = (csr_mcycle & 0xFFFFFFFF00000000ULL) | value;
        break;
    case CSR_MCYCLEH:
        csr_mcycle = (csr_mcycle & 0x00000000FFFFFFFFULL) | ((uint64_t)value << 32);
        break;
    case CSR_MINSTRET:
        csr_minstret = (csr_minstret & 0xFFFFFFFF00000000ULL) | value;
        break;
    case CSR_MINSTRETH:
        csr_minstret = (csr_minstret & 0x00000000FFFFFFFFULL) | ((uint64_t)value << 32);
        break;

    // User-level counters (read-only)
    case CSR_CYCLE:
    case CSR_CYCLEH:
    case CSR_TIME:
    case CSR_TIMEH:
    case CSR_INSTRET:
    case CSR_INSTRETH:

    // Machine information registers (read-only)
    case CSR_MVENDORID:
    case CSR_MARCHID:
    case CSR_MIMPID:
    case CSR_MHARTID:
    case CSR_MISA:  // MISA is read-only
        // Read-only CSRs, ignore writes
        break;

    default:
        std::cerr << "Warning: Writing unknown CSR 0x" << std::hex << csr
                  << std::endl;
        break;
    }
}

// Take trap (exception or interrupt)
void KV32Simulator::take_trap(uint32_t cause, uint32_t tval) {
    // Save current PC to MEPC
    csr_mepc = pc;

    // Set cause and trap value
    csr_mcause = cause;
    csr_mtval = tval;

    // Update MPIE, MIE, and MPP in mstatus
    // MPIE = old MIE, MIE = 0, MPP = 3 (M-mode, per RISC-V spec)
    uint32_t mie = (csr_mstatus >> 3) & 1;
    csr_mstatus = (csr_mstatus & ~0x1888) | (mie << 7) | (3 << 11); // MPIE = MIE, MIE = 0, MPP = 3

    // Jump to trap handler
    pc = csr_mtvec & ~3; // Vectored mode not yet supported
    trap_count++;         // track how many traps have fired (useful for debugging)

    if (wfi_spin_active) {
        // Interrupt fired from inside the WFI spin loop — this is the normal
        // wakeup path.  Mark that WFI recently completed so that cascaded
        // interrupts which fire after MRET (e.g. MSIP triggered by a timer ISR)
        // are not mistaken for a "pre-WFI" interrupt.
        wfi_recently_completed = true;
    } else if (!wfi_recently_completed) {
        // Interrupt fired outside the WFI spin AND we are not inside a cascade
        // from a recent WFI wakeup.  This means the interrupt was fully serviced
        // before WFI was dispatched, mirroring the RTL irq_was_pending sticky
        // flag.  Set irq_before_wfi so the next WFI exits immediately (NOP).
        irq_before_wfi = true;
    }
    // If wfi_recently_completed is true we are in a cascade from the previous
    // WFI wakeup — do nothing: neither set irq_before_wfi nor change the flag.
}

// Check for pending interrupts
void KV32Simulator::check_interrupts() {
    // ── PLIC: update IRQ sources from peripherals ──────────────────────────
    // Sources: [1]=UART, [2]=SPI, [3]=I2C, [4]=DMA, [5]=GPIO, [6]=TIMER  (matches kv32_soc.sv wiring)
    uint32_t plic_src = 0;
    if (uart->get_irq()) plic_src |= (1u << 1);
    if (spi->get_irq())  plic_src |= (1u << 2);
    if (i2c->get_irq())  plic_src |= (1u << 3);
    if (dma->get_irq())  plic_src |= (1u << KV_PLIC_SRC_DMA);
    if (gpio->get_irq()) plic_src |= (1u << KV_PLIC_SRC_GPIO);
    if (timer->get_irq()) plic_src |= (1u << KV_PLIC_SRC_TIMER);
    plic->update_irq_sources(plic_src);

    // ── Update MIP bits ───────────────────────────────────────────────────
    // MTIP (bit 7) from CLINT
    if (clint->get_timer_interrupt()) {
        csr_mip |= (1 << 7);
    } else {
        csr_mip &= ~(1 << 7);
    }

    // MSIP (bit 3) from CLINT
    if (clint->get_software_interrupt()) {
        csr_mip |= (1 << 3);
    } else {
        csr_mip &= ~(1 << 3);
    }

    // MEIP (bit 11) from PLIC
    if (plic->get_external_interrupt()) {
        csr_mip |= (1 << 11);
    } else {
        csr_mip &= ~(1 << 11);
    }

    // Check if machine interrupts are globally enabled
    uint32_t mie_bit = (csr_mstatus >> 3) & 1;
    if (!mie_bit)
        return;

    // Dispatch highest-priority pending+enabled interrupt
    uint32_t pending = csr_mip & csr_mie;

    if (pending & (1 << 11)) {       // External interrupt (PLIC)
        take_trap(CAUSE_MACHINE_EXTERNAL_INT, 0);
    } else if (pending & (1 << 7)) { // Timer interrupt
        take_trap(CAUSE_MACHINE_TIMER_INT, 0);
    } else if (pending & (1 << 3)) { // Software interrupt
        take_trap(CAUSE_MACHINE_SOFTWARE_INT, 0);
    }
}

void KV32Simulator::register_device_slave(uint32_t base, uint32_t size, Device* device, const char* name) {
    if (!device) {
        return;
    }

    SlaveRegion region;
    region.base = base;
    region.size = size;
    region.device = device;
    region.name = name ? name : "DEVICE";
    slaves.push_back(region);
}

const KV32Simulator::SlaveRegion* KV32Simulator::find_slave(uint32_t addr) const {
    for (const auto& slave : slaves) {
        if (addr >= slave.base && addr <= slave.base + (slave.size - 1)) {
            return &slave;
        }
    }
    return nullptr;
}

uint32_t KV32Simulator::bus_read(uint32_t addr, int size, bool* handled) {
    last_bus_error = false;  // Clear before each bus access
    const SlaveRegion* slave = find_slave(addr);
    if (!slave) {
        if (handled) {
            *handled = false;
        }
        return 0;
    }

    if (handled) {
        *handled = true;
    }

    uint32_t offset = addr - slave->base;
    slave->device->last_bus_error = false;
    uint32_t val = slave->device->read(offset, size);
    last_bus_error = slave->device->last_bus_error;
    return val;
}

bool KV32Simulator::bus_write(uint32_t addr, uint32_t value, int size) {
    last_bus_error = false;  // Clear before each bus access
    const SlaveRegion* slave = find_slave(addr);
    if (!slave) {
        return false;
    }

    uint32_t offset = addr - slave->base;
    slave->device->last_bus_error = false;
    slave->device->write(offset, value, size);
    last_bus_error = slave->device->last_bus_error;
    return true;
}

void KV32Simulator::tick_slaves() {
    for (const auto& slave : slaves) {
        if (slave.device != nullptr) {
            slave.device->tick();
        }
    }
}

void KV32Simulator::untick_slaves() {
    for (const auto& slave : slaves) {
        if (slave.device != nullptr) {
            slave.device->untick();
        }
    }
}

// Memory access
uint32_t KV32Simulator::read_mem(uint32_t addr, int size, bool is_fetch) {
    // Check for misaligned access
    if ((size == 2 && (addr & 0x1)) || (size == 4 && (addr & 0x3))) {
        // Misaligned access - raise exception
        // Update mstatus: MPIE = MIE, MIE = 0, MPP = 3 (M-mode)
        uint32_t mie_bit = (csr_mstatus >> 3) & 1;
        csr_mstatus = (csr_mstatus & ~0x1888) | (mie_bit << 7) | (3 << 11);
        // Set mcause to load address misaligned (4)
        write_csr(CSR_MCAUSE, 4);
        write_csr(CSR_MTVAL, addr);
        write_csr(CSR_MEPC, pc);
        // Set exception flag to jump to trap handler
        exception_occurred = true;
        uint32_t mtvec = read_csr(CSR_MTVEC);
        exception_pc = mtvec & ~0x3; // Clear mode bits
        return 0;
    }

    // Check watchpoints before memory read (if GDB enabled and not during instruction fetch)
    if (gdb_enabled && gdb_ctx && addr != pc) {
        gdb_context_t* gdb = (gdb_context_t*)gdb_ctx;
        if (gdb_stub_check_watchpoint_read(gdb, addr, size)) {
            gdb->should_stop = true;
            std::cout << "Read watchpoint hit at 0x" << std::hex << addr
                      << " size=" << std::dec << size << std::endl;
        }
    }

    // Handle tohost
    if (addr == tohost_addr && tohost_addr != 0) {
        return 0;
    }

    bool handled = false;
    uint32_t value = bus_read(addr, size, &handled);
    if (!handled) {
        // Unmapped address: raise instruction fetch fault (cause 1) or load access fault (cause 5)
        uint32_t cause = is_fetch ? CAUSE_FETCH_ACCESS : CAUSE_LOAD_ACCESS;
        uint32_t mie_bit = (csr_mstatus >> 3) & 1;
        csr_mstatus = (csr_mstatus & ~0x1888) | (mie_bit << 7) | (3 << 11);
        write_csr(CSR_MCAUSE, cause);
        write_csr(CSR_MTVAL,  addr);
        write_csr(CSR_MEPC,   pc);
        exception_occurred = true;
        exception_pc = read_csr(CSR_MTVEC) & ~0x3;
        return 0;
    }
    // AXI SLVERR from peripheral → load access fault (cause 5)
    if (last_bus_error) {
        uint32_t mie_bit = (csr_mstatus >> 3) & 1;
        csr_mstatus = (csr_mstatus & ~0x1888) | (mie_bit << 7) | (3 << 11);
        write_csr(CSR_MCAUSE, CAUSE_LOAD_ACCESS);
        write_csr(CSR_MTVAL,  addr);
        write_csr(CSR_MEPC,   pc);
        exception_occurred = true;
        exception_pc = read_csr(CSR_MTVEC) & ~0x3;
        return 0;
    }
    return value;
}

void KV32Simulator::write_mem(uint32_t addr, uint32_t value, int size) {
    // Check for misaligned access
    if ((size == 2 && (addr & 0x1)) || (size == 4 && (addr & 0x3))) {
        // Misaligned access - raise exception
        // Update mstatus: MPIE = MIE, MIE = 0, MPP = 3 (M-mode)
        uint32_t mie_bit = (csr_mstatus >> 3) & 1;
        csr_mstatus = (csr_mstatus & ~0x1888) | (mie_bit << 7) | (3 << 11);
        // Set mcause to store/AMO address misaligned (6)
        write_csr(CSR_MCAUSE, 6);
        write_csr(CSR_MTVAL, addr);
        write_csr(CSR_MEPC, pc);
        // Set exception flag to jump to trap handler
        exception_occurred = true;
        uint32_t mtvec = read_csr(CSR_MTVEC);
        exception_pc = mtvec & ~0x3; // Clear mode bits
        return;
    }

    // Check watchpoints before memory write (if GDB enabled)
    if (gdb_enabled && gdb_ctx) {
        gdb_context_t* gdb = (gdb_context_t*)gdb_ctx;
        if (gdb_stub_check_watchpoint_write(gdb, addr, size)) {
            gdb->should_stop = true;
            std::cout << "Write watchpoint hit at 0x" << std::hex << addr
                      << " size=" << std::dec << size
                      << " value=0x" << std::hex << value << std::endl;
        }
    }

    // Handle tohost
    if (addr == tohost_addr && tohost_addr != 0) {
        if (value != 0) {
            exit_code = (value >> 1) & 0x7FFFFFFF;
            running = false;
            std::cout << "\n[EXIT] tohost write: exit code = " << exit_code
                      << std::endl;
        }
        return;
    }

    if (!bus_write(addr, value, size)) {
        // Unmapped address: raise store access fault (cause 7)
        uint32_t mie_bit = (csr_mstatus >> 3) & 1;
        csr_mstatus = (csr_mstatus & ~0x1888) | (mie_bit << 7) | (3 << 11);
        write_csr(CSR_MCAUSE, CAUSE_STORE_ACCESS);
        write_csr(CSR_MTVAL,  addr);
        write_csr(CSR_MEPC,   pc);
        exception_occurred = true;
        exception_pc = read_csr(CSR_MTVEC) & ~0x3;
        return;
    }
    // AXI SLVERR from peripheral → store access fault (cause 7)
    if (last_bus_error) {
        uint32_t mie_bit = (csr_mstatus >> 3) & 1;
        csr_mstatus = (csr_mstatus & ~0x1888) | (mie_bit << 7) | (3 << 11);
        write_csr(CSR_MCAUSE, CAUSE_STORE_ACCESS);
        write_csr(CSR_MTVAL,  addr);
        write_csr(CSR_MEPC,   pc);
        exception_occurred = true;
        exception_pc = read_csr(CSR_MTVEC) & ~0x3;
        return;
    }

    if (magic != nullptr) {
        int magic_exit_code = 0;
        if (magic->consume_exit_request(&magic_exit_code)) {
            exit_code = magic_exit_code;
            running = false;
            return;
        }
    }
}

// Sign extend
int32_t KV32Simulator::sign_extend(uint32_t value, int bits) {
    uint32_t sign_bit = 1U << (bits - 1);
    if (value & sign_bit) {
        return value | (~((1U << bits) - 1));
    }
    return value;
}

// ── Compressed-instruction expansion helpers ────────────────────────────────
// Sign-extend a val of width `bits` to 32 bits.
static inline int32_t c_sext(uint32_t val, int bits) {
    uint32_t sign_bit = 1U << (bits - 1);
    if (val & sign_bit)
        return (int32_t)(val | (~((1U << bits) - 1)));
    return (int32_t)val;
}

// Encode a JAL instruction: JAL rd, imm (imm is a signed PC-relative offset)
static uint32_t encode_jal(uint32_t rd, int32_t imm) {
    uint32_t u = (uint32_t)imm;
    return (((u >> 20) & 1) << 31) |    // imm[20]
           (((u >>  1) & 0x3FF) << 21) | // imm[10:1]
           (((u >> 11) & 1) << 20) |    // imm[11]
           (((u >> 12) & 0xFF) << 12) | // imm[19:12]
           (rd << 7) | 0x6F;
}

// Encode a B-type branch: funct3, rs1, rs2, signed imm
static uint32_t encode_branch(uint32_t funct3, uint32_t rs1, uint32_t rs2, int32_t imm) {
    uint32_t u = (uint32_t)imm;
    return (((u >> 12) & 1) << 31) |
           (((u >>  5) & 0x3F) << 25) |
           (rs2 << 20) | (rs1 << 15) | (funct3 << 12) |
           (((u >>  1) & 0xF) << 8) |
           (((u >> 11) & 1) << 7) |
           0x63;
}

// Extract C.J / C.JAL / C.J offset (12-bit signed)
static int32_t c_j_offset(uint16_t ci) {
    return c_sext(
        ((ci >> 1) & 0x800) | ((ci >> 7) & 0x10) | ((ci >> 1) & 0x300) |
        ((ci << 2) & 0x400) | ((ci >> 1) & 0x40) | ((ci << 1) & 0x80) |
        ((ci >> 2) & 0xE)  | ((ci << 3) & 0x20), 12);
}

// Extract C.BEQZ / C.BNEZ offset (9-bit signed)
static int32_t c_b_offset(uint16_t ci) {
    return c_sext(
        ((ci >> 4) & 0x100) | ((ci >> 7) & 0x18) | ((ci << 1) & 0xC0) |
        ((ci >> 2) & 0x6)  | ((ci << 3) & 0x20), 9);
}

// Expand a 16-bit compressed instruction to its 32-bit equivalent.
// Returns 0 for illegal/unsupported encodings (caller must raise illegal-instruction).
static uint32_t expand_compressed(uint16_t ci) {
    uint32_t quad   = ci & 0x3;
    uint32_t funct3 = (ci >> 13) & 0x7;

    if (quad == 0) {
        // Quadrant 0
        uint32_t rd_p  = ((ci >> 2) & 0x7) + 8; // rd'/rs2' → x8–x15
        uint32_t rs1_p = ((ci >> 7) & 0x7) + 8; // rs1'     → x8–x15

        switch (funct3) {
        case 0x0: { // C.ADDI4SPN → ADDI rd', x2, nzuimm
            uint32_t nzuimm =
                ((ci >> 7) & 0x30) | ((ci >> 1) & 0x3C0) |
                ((ci >> 4) & 0x4)  | ((ci >> 2) & 0x8);
            if (nzuimm == 0) return 0; // illegal
            // ADDI rd', x2, nzuimm  (I-type, funct3=0, opcode=0x13)
            return (nzuimm << 20) | (2 << 15) | (0 << 12) | (rd_p << 7) | 0x13;
        }
        case 0x2: { // C.LW → LW rd', offset(rs1')
            uint32_t uimm =
                ((ci >> 7) & 0x38) | ((ci >> 4) & 0x4) | ((ci << 1) & 0x40);
            // LW rd', uimm(rs1')  (I-type, funct3=2, opcode=0x03)
            return (uimm << 20) | (rs1_p << 15) | (2 << 12) | (rd_p << 7) | 0x03;
        }
        case 0x6: { // C.SW → SW rs2', offset(rs1')
            uint32_t uimm =
                ((ci >> 7) & 0x38) | ((ci >> 4) & 0x4) | ((ci << 1) & 0x40);
            // SW rs2', uimm(rs1')  (S-type, funct3=2, opcode=0x23)
            uint32_t imm11_5 = (uimm >> 5) & 0x7F;
            uint32_t imm4_0  =  uimm & 0x1F;
            return (imm11_5 << 25) | (rd_p << 20) | (rs1_p << 15) |
                   (2 << 12) | (imm4_0 << 7) | 0x23;
        }
        default:
            return 0; // FP / reserved
        }
    }

    if (quad == 1) {
        // Quadrant 1
        uint32_t rd_rs1 = (ci >> 7) & 0x1F;

        switch (funct3) {
        case 0x0: { // C.NOP / C.ADDI → ADDI rd, rd, nzimm
            int32_t nzimm = c_sext(((ci >> 7) & 0x20) | ((ci >> 2) & 0x1F), 6);
            // ADDI rd, rd, nzimm  (I-type, funct3=0, opcode=0x13)
            return ((uint32_t)(nzimm & 0xFFF) << 20) | (rd_rs1 << 15) |
                   (0 << 12) | (rd_rs1 << 7) | 0x13;
        }
        case 0x1: { // C.JAL (RV32) → JAL x1, offset
            int32_t imm = c_j_offset(ci);
            return encode_jal(1, imm);
        }
        case 0x2: { // C.LI → ADDI rd, x0, imm  (rd=0 is a HINT → NOP)
            int32_t imm = c_sext(((ci >> 7) & 0x20) | ((ci >> 2) & 0x1F), 6);
            return ((uint32_t)(imm & 0xFFF) << 20) | (0 << 15) |
                   (0 << 12) | (rd_rs1 << 7) | 0x13;
        }
        case 0x3: {
            if (rd_rs1 == 2) { // C.ADDI16SP → ADDI x2, x2, nzimm
                int32_t nzimm = c_sext(
                    ((ci >> 3) & 0x200) | ((ci >> 2) & 0x10) | ((ci << 1) & 0x40) |
                    ((ci << 4) & 0x180) | ((ci << 3) & 0x20), 10);
                if (nzimm == 0) return 0; // illegal
                return ((uint32_t)(nzimm & 0xFFF) << 20) | (2 << 15) |
                       (0 << 12) | (2 << 7) | 0x13;
            } else { // C.LUI → LUI rd, nzimm[17:12]  (rd=0 is RESERVED, treat as NOP)
                int32_t nzimm6 = c_sext(((ci >> 7) & 0x20) | ((ci >> 2) & 0x1F), 6);
                if (nzimm6 == 0) return 0; // illegal (nzimm must be non-zero)
                uint32_t uimm20 = (uint32_t)(nzimm6) & 0xFFFFF; // upper 20 bits
                return (uimm20 << 12) | (rd_rs1 << 7) | 0x37;
            }
        }
        case 0x4: { // Arithmetic
            uint32_t funct2   = (ci >> 10) & 0x3;
            uint32_t rd_p     = ((ci >> 7) & 0x7) + 8;
            uint32_t rs2_p    = ((ci >> 2) & 0x7) + 8;

            switch (funct2) {
            case 0x0: { // C.SRLI → SRLI rd', rd', shamt
                uint32_t shamt = ((ci >> 7) & 0x20) | ((ci >> 2) & 0x1F);
                // SRLI: funct7=0x00, funct3=5, opcode=0x13
                return (0 << 25) | (shamt << 20) | (rd_p << 15) |
                       (5 << 12) | (rd_p << 7) | 0x13;
            }
            case 0x1: { // C.SRAI → SRAI rd', rd', shamt
                uint32_t shamt = ((ci >> 7) & 0x20) | ((ci >> 2) & 0x1F);
                // SRAI: funct7=0x20, funct3=5, opcode=0x13
                return (0x20 << 25) | (shamt << 20) | (rd_p << 15) |
                       (5 << 12) | (rd_p << 7) | 0x13;
            }
            case 0x2: { // C.ANDI → ANDI rd', rd', imm
                int32_t imm = c_sext(((ci >> 7) & 0x20) | ((ci >> 2) & 0x1F), 6);
                return ((uint32_t)(imm & 0xFFF) << 20) | (rd_p << 15) |
                       (7 << 12) | (rd_p << 7) | 0x13;
            }
            case 0x3: {
                uint32_t f1      = (ci >> 12) & 0x1;
                uint32_t f2_low  = (ci >> 5) & 0x3;
                if (f1 == 0) {
                    switch (f2_low) {
                    case 0x0: // C.SUB → SUB rd', rd', rs2' (funct7=0x20)
                        return (0x20 << 25) | (rs2_p << 20) | (rd_p << 15) |
                               (0 << 12) | (rd_p << 7) | 0x33;
                    case 0x1: // C.XOR → XOR rd', rd', rs2'
                        return (0 << 25) | (rs2_p << 20) | (rd_p << 15) |
                               (4 << 12) | (rd_p << 7) | 0x33;
                    case 0x2: // C.OR → OR rd', rd', rs2'
                        return (0 << 25) | (rs2_p << 20) | (rd_p << 15) |
                               (6 << 12) | (rd_p << 7) | 0x33;
                    case 0x3: // C.AND → AND rd', rd', rs2'
                        return (0 << 25) | (rs2_p << 20) | (rd_p << 15) |
                               (7 << 12) | (rd_p << 7) | 0x33;
                    }
                }
                return 0; // f1=1: RV64-only (C.ADDW / C.SUBW)
            }
            }
            return 0;
        }
        case 0x5: { // C.J → JAL x0, offset
            int32_t imm = c_j_offset(ci);
            return encode_jal(0, imm);
        }
        case 0x6: { // C.BEQZ → BEQ rs1', x0, offset
            uint32_t rs1_p = ((ci >> 7) & 0x7) + 8;
            int32_t imm = c_b_offset(ci);
            return encode_branch(0, rs1_p, 0, imm);
        }
        case 0x7: { // C.BNEZ → BNE rs1', x0, offset
            uint32_t rs1_p = ((ci >> 7) & 0x7) + 8;
            int32_t imm = c_b_offset(ci);
            return encode_branch(1, rs1_p, 0, imm);
        }
        }
        return 0;
    }

    if (quad == 2) {
        // Quadrant 2
        uint32_t rd_rs1 = (ci >> 7) & 0x1F;
        uint32_t rs2    = (ci >> 2) & 0x1F;

        switch (funct3) {
        case 0x0: { // C.SLLI → SLLI rd, rd, shamt  (rd=0 or shamt=0 are HINTs → NOP)
            uint32_t shamt = ((ci >> 7) & 0x20) | ((ci >> 2) & 0x1F);
            // SLLI: funct7=0, funct3=1, opcode=0x13
            return (0 << 25) | (shamt << 20) | (rd_rs1 << 15) |
                   (1 << 12) | (rd_rs1 << 7) | 0x13;
        }
        case 0x2: { // C.LWSP → LW rd, offset(x2)
            uint32_t uimm = ((ci >> 7) & 0x20) | ((ci >> 2) & 0x1C) | ((ci << 4) & 0xC0);
            if (rd_rs1 == 0) return 0; // illegal
            return (uimm << 20) | (2 << 15) | (2 << 12) | (rd_rs1 << 7) | 0x03;
        }
        case 0x4: {
            uint32_t f1 = (ci >> 12) & 0x1;
            if (f1 == 0) {
                if (rs2 == 0) { // C.JR → JALR x0, rs1, 0
                    if (rd_rs1 == 0) return 0; // illegal
                    return (0 << 20) | (rd_rs1 << 15) | (0 << 12) | (0 << 7) | 0x67;
                } else { // C.MV → ADD rd, x0, rs2
                    return (0 << 25) | (rs2 << 20) | (0 << 15) |
                           (0 << 12) | (rd_rs1 << 7) | 0x33;
                }
            } else {
                if (rd_rs1 == 0 && rs2 == 0) { // C.EBREAK
                    return 0x00100073;
                } else if (rs2 == 0) { // C.JALR → JALR x1, rs1, 0
                    return (0 << 20) | (rd_rs1 << 15) | (0 << 12) | (1 << 7) | 0x67;
                } else { // C.ADD → ADD rd, rd, rs2
                    return (0 << 25) | (rs2 << 20) | (rd_rs1 << 15) |
                           (0 << 12) | (rd_rs1 << 7) | 0x33;
                }
            }
        }
        case 0x6: { // C.SWSP → SW rs2, offset(x2)
            uint32_t uimm = ((ci >> 7) & 0x3C) | ((ci >> 1) & 0xC0);
            uint32_t imm11_5 = (uimm >> 5) & 0x7F;
            uint32_t imm4_0  =  uimm & 0x1F;
            return (imm11_5 << 25) | (rs2 << 20) | (2 << 15) |
                   (2 << 12) | (imm4_0 << 7) | 0x23;
        }
        default:
            return 0; // FP / reserved
        }
    }

    return 0; // quad==3: 32-bit instruction, should not be called
}

// Execute one instruction
void KV32Simulator::step() {
    if (!running)
        return;

    // Clear exception flag from previous instruction
    exception_occurred = false;

    // Check for interrupts before fetching instruction.
    // We snapshot MIE and trap_count first so we can detect whether this step
    // runs cleanly in user mode (MIE=1, no new trap).  When that happens and
    // wfi_recently_completed is still set from a previous WFI wakeup, it means
    // all cascaded interrupts have settled and the flag must be cleared so it
    // does not suppress a future genuine pre-WFI interrupt detection.
    uint32_t mie_before_check = (csr_mstatus >> 3) & 1;
    uint64_t tc_before_check  = trap_count;
    check_interrupts();
    // Clear the cascade-window flag on the first clean user-mode step.
    if (mie_before_check && trap_count == tc_before_check)
        wfi_recently_completed = false;

    // Tick all registered slave devices (once per traced/retired instruction).
    // Placed here so that interrupt detection in check_interrupts() above sees
    // the device state after the *previous* instruction retired.
    tick_slaves();

    // ── Instruction fetch (supports RVC 16-bit and 32-bit) ─────────────────
    // All bus devices support 4-byte aligned reads.  We always issue a
    // word-aligned fetch; for a PC that is 2-byte but not 4-byte aligned we
    // may need a second aligned fetch to get the upper halfword.
    uint32_t aligned_pc = pc & ~3u;
    uint32_t fetch_w0   = read_mem(aligned_pc, 4, true);
    uint32_t exec_pc    = pc; // Save PC for logging

    if (exception_occurred) {
        untick_slaves();
        inst_count--; csr_mcycle--; csr_minstret--;
        pc = exception_pc;
        return;
    }

    // Extract the 16-bit lower half at the actual PC.
    uint32_t pc_off  = pc & 2u;          // 0 or 2
    uint16_t inst_lo = (uint16_t)(fetch_w0 >> (pc_off * 8));

    bool     is_compressed = (inst_lo & 0x3) != 0x3;
    uint32_t inst_size     = is_compressed ? 2u : 4u;
    uint32_t orig_inst;  // Raw encoding used for trace log
    uint32_t inst;       // Instruction to decode (expanded to 32-bit if RVC)

    if (is_compressed) {
        orig_inst         = inst_lo;
        uint32_t expanded = expand_compressed(inst_lo);
        if (expanded == 0) {
            // Illegal compressed instruction
            std::cerr << "Illegal compressed instruction: 0x" << std::hex
                      << inst_lo << " at PC 0x" << pc << std::endl;
            take_trap(CAUSE_ILLEGAL_INSTRUCTION, inst_lo);
            untick_slaves();
            inst_count--; csr_mcycle--; csr_minstret--;
            return;
        }
        inst = expanded;
    } else {
        // 32-bit instruction: may span two aligned words if pc is +2 offset.
        uint32_t inst32;
        if (pc_off == 0) {
            // Fully contained in the first aligned word.
            inst32 = fetch_w0;
        } else {
            // Upper halfword is in the next aligned word.
            uint32_t fetch_w1 = read_mem(aligned_pc + 4, 4, true);
            if (exception_occurred) {
                untick_slaves();
                inst_count--; csr_mcycle--; csr_minstret--;
                pc = exception_pc;
                return;
            }
            inst32 = (fetch_w0 >> 16) | (fetch_w1 << 16);
        }
        orig_inst = inst32;
        inst      = inst32;
    }

    uint32_t opcode = inst & 0x7F;
    uint32_t rd = (inst >> 7) & 0x1F;
    uint32_t funct3 = (inst >> 12) & 0x7;
    uint32_t rs1 = (inst >> 15) & 0x1F;
    uint32_t rs2 = (inst >> 20) & 0x1F;
    uint32_t funct7 = (inst >> 25) & 0x7F;

    uint32_t next_pc = pc + inst_size;
    inst_count++;
    // In the software simulator every instruction counts as exactly one "cycle".
    // Both counters are always equal here, which matches the RTL trace_mode=1
    // behaviour where cycle/time CSR reads return minstret (instruction count)
    // rather than the real wall-clock mcycle (see read_csr() and kv32_csr.sv).
    csr_mcycle++;     // Increment machine cycle counter (== minstret in this sim)
    csr_minstret++;   // Increment machine instructions retired counter

    // Trace variables
    int trace_rd = -1;
    uint32_t trace_rd_val = 0;
    bool trace_has_mem = false;
    uint32_t trace_mem_addr = 0;
    uint32_t trace_mem_val = 0;
    bool trace_is_store = false;
    bool trace_is_csr = false;
    uint32_t trace_csr_num = 0;

    // Decode and execute
    switch (opcode) {
    case 0x37: { // LUI
        uint32_t imm = inst & 0xFFFFF000;
        if (rd != 0) {
            regs[rd] = imm;
            trace_rd = rd;
            trace_rd_val = imm;
        }
        break;
    }
    case 0x17: { // AUIPC
        uint32_t imm = inst & 0xFFFFF000;
        uint32_t result = pc + imm;
        if (rd != 0) {
            regs[rd] = result;
            trace_rd = rd;
            trace_rd_val = result;
        }
        break;
    }
    case 0x6F: { // JAL
        int32_t imm = sign_extend(
            ((inst >> 31) << 20) | (((inst >> 12) & 0xFF) << 12) |
                (((inst >> 20) & 0x1) << 11) | (((inst >> 21) & 0x3FF) << 1),
            21);
        uint32_t link = pc + inst_size;
        next_pc = pc + imm;
        // Per spec: rd is written only if target is not misaligned
        // (misaligned target raises instruction-address-misaligned exception
        //  which must not commit the rd write)
        if ((next_pc & 0x1) == 0) {
            if (rd != 0) {
                regs[rd] = link;
                trace_rd = rd;
                trace_rd_val = link;
            }
        }
        break;
    }
    case 0x67: { // JALR
        int32_t imm = sign_extend((inst >> 20) & 0xFFF, 12);
        uint32_t target = (regs[rs1] + imm) & ~1u;
        uint32_t link = pc + inst_size;
        next_pc = target;
        // Per spec: rd is written only if target is not misaligned
        if ((next_pc & 0x1) == 0) {
            if (rd != 0) {
                regs[rd] = link;
                trace_rd = rd;
                trace_rd_val = link;
            }
        }
        break;
    }
    case 0x63: { // Branch
        int32_t imm = sign_extend(
            ((inst >> 31) << 12) | (((inst >> 7) & 0x1) << 11) |
                (((inst >> 25) & 0x3F) << 5) | (((inst >> 8) & 0xF) << 1),
            13);
        bool taken = false;
        switch (funct3) {
        case 0x0:
            taken = (regs[rs1] == regs[rs2]);
            break; // BEQ
        case 0x1:
            taken = (regs[rs1] != regs[rs2]);
            break; // BNE
        case 0x4:
            taken = ((int32_t)regs[rs1] < (int32_t)regs[rs2]);
            break; // BLT
        case 0x5:
            taken = ((int32_t)regs[rs1] >= (int32_t)regs[rs2]);
            break; // BGE
        case 0x6:
            taken = (regs[rs1] < regs[rs2]);
            break; // BLTU
        case 0x7:
            taken = (regs[rs1] >= regs[rs2]);
            break; // BGEU
        }
        if (taken)
            next_pc = pc + imm;
        break;
    }
    case 0x03: { // Load
        int32_t imm = sign_extend((inst >> 20) & 0xFFF, 12);
        uint32_t addr = regs[rs1] + imm;
        uint32_t value = 0;
        switch (funct3) {
        case 0x0:
            value = sign_extend(read_mem(addr, 1), 8);
            break; // LB
        case 0x1:
            value = sign_extend(read_mem(addr, 2), 16);
            break; // LH
        case 0x2:
            value = read_mem(addr, 4);
            break; // LW
        case 0x4:
            value = read_mem(addr, 1);
            break; // LBU
        case 0x5:
            value = read_mem(addr, 2);
            break; // LHU
        }
        if (rd != 0 && !exception_occurred) {
            regs[rd] = value;
            trace_rd = rd;
            trace_rd_val = value;
        }
        if (!exception_occurred) {
            trace_has_mem = true;
            trace_mem_addr = addr;
            trace_mem_val = value;
            trace_is_store = false; // Load instruction
        }
        break;
    }
    case 0x23: { // Store
        int32_t imm =
            sign_extend(((inst >> 25) << 5) | ((inst >> 7) & 0x1F), 12);
        uint32_t addr = regs[rs1] + imm;
        uint32_t value = regs[rs2];
        switch (funct3) {
        case 0x0:
            write_mem(addr, value, 1);
            break; // SB
        case 0x1:
            write_mem(addr, value, 2);
            break; // SH
        case 0x2:
            write_mem(addr, value, 4);
            break; // SW
        }
        // Always record the store's mem trace info so the exception handler
        // can emit a log_commit for bus-error stores (cause=7).  The RTL retires
        // the store instruction before the AXI B-channel SLVERR comes back, so
        // the store DOES appear in the RTL trace even when it faults.
        // Misaligned stores (cause=6) are handled below — they are NOT logged.
        trace_has_mem  = true;
        trace_mem_addr = addr;
        trace_mem_val  = value;
        trace_is_store = true;
        break;
    }
    case 0x13: { // I-type ALU
        int32_t imm = sign_extend((inst >> 20) & 0xFFF, 12);
        uint32_t result = 0;
        switch (funct3) {
        case 0x0:
            result = regs[rs1] + imm;
            break; // ADDI
        case 0x2:
            result = ((int32_t)regs[rs1] < imm) ? 1 : 0;
            break; // SLTI
        case 0x3:
            result = (regs[rs1] < (uint32_t)imm) ? 1 : 0;
            break; // SLTIU
        case 0x4:
            result = regs[rs1] ^ imm;
            break; // XORI
        case 0x6:
            result = regs[rs1] | imm;
            break; // ORI
        case 0x7:
            result = regs[rs1] & imm;
            break; // ANDI
        case 0x1:
            result = regs[rs1] << (imm & 0x1F);
            break; // SLLI
        case 0x5:
            if (funct7 == 0x00)
                result = regs[rs1] >> (imm & 0x1F); // SRLI
            else
                result = (int32_t)regs[rs1] >> (imm & 0x1F); // SRAI
            break;
        }
        if (rd != 0) {
            regs[rd] = result;
            trace_rd = rd;
            trace_rd_val = result;
        }
        break;
    }
    case 0x33: { // R-type ALU
        uint32_t result = 0;
        switch (funct3) {
        case 0x0:
            if (funct7 == 0x00)
                result = regs[rs1] + regs[rs2]; // ADD
            else if (funct7 == 0x20)
                result = regs[rs1] - regs[rs2]; // SUB
            else if (funct7 == 0x01)
                result = regs[rs1] * regs[rs2]; // MUL
            break;
        case 0x1:
            if (funct7 == 0x00)
                result = regs[rs1] << (regs[rs2] & 0x1F); // SLL
            else if (funct7 == 0x01) {
                // MULH: signed x signed, upper 32 bits
                int64_t a = (int32_t)regs[rs1];
                int64_t b = (int32_t)regs[rs2];
                result = (int32_t)((a * b) >> 32);
            }
            break;
        case 0x2:
            if (funct7 == 0x00)
                result =
                    ((int32_t)regs[rs1] < (int32_t)regs[rs2]) ? 1 : 0; // SLT
            else if (funct7 == 0x01)
                result = ((int64_t)(int32_t)regs[rs1] * (uint32_t)regs[rs2]) >>
                         32; // MULHSU
            break;
        case 0x3:
            if (funct7 == 0x00)
                result = (regs[rs1] < regs[rs2]) ? 1 : 0; // SLTU
            else if (funct7 == 0x01)
                result = ((uint64_t)regs[rs1] * regs[rs2]) >> 32; // MULHU
            break;
        case 0x4:
            if (funct7 == 0x00)
                result = regs[rs1] ^ regs[rs2]; // XOR
            else if (funct7 == 0x01) {
                // DIV: signed division with special cases
                int32_t dividend = (int32_t)regs[rs1];
                int32_t divisor = (int32_t)regs[rs2];
                if (divisor == 0) {
                    result = -1; // Division by zero
                } else if (dividend == INT32_MIN && divisor == -1) {
                    result = INT32_MIN; // Overflow case
                } else {
                    result = dividend / divisor;
                }
            }
            break;
        case 0x5:
            if (funct7 == 0x00)
                result = regs[rs1] >> (regs[rs2] & 0x1F); // SRL
            else if (funct7 == 0x20)
                result = (int32_t)regs[rs1] >> (regs[rs2] & 0x1F); // SRA
            else if (funct7 == 0x01) {
                // DIVU: unsigned division with special cases
                uint32_t dividend = regs[rs1];
                uint32_t divisor = regs[rs2];
                if (divisor == 0) {
                    result = 0xFFFFFFFF; // Division by zero returns all 1s
                } else {
                    result = dividend / divisor;
                }
            }
            break;
        case 0x6:
            if (funct7 == 0x00)
                result = regs[rs1] | regs[rs2]; // OR
            else if (funct7 == 0x01) {
                // REM: signed remainder with special cases
                int32_t dividend = (int32_t)regs[rs1];
                int32_t divisor = (int32_t)regs[rs2];
                if (divisor == 0) {
                    result = dividend; // Remainder by zero returns dividend
                } else if (dividend == INT32_MIN && divisor == -1) {
                    result = 0; // Overflow case
                } else {
                    result = dividend % divisor;
                }
            }
            break;
        case 0x7:
            if (funct7 == 0x00)
                result = regs[rs1] & regs[rs2]; // AND
            else if (funct7 == 0x01) {
                // REMU: unsigned remainder with special cases
                uint32_t dividend = regs[rs1];
                uint32_t divisor = regs[rs2];
                if (divisor == 0) {
                    result = dividend; // Remainder by zero returns dividend
                } else {
                    result = dividend % divisor;
                }
            }
            break;
        }
        if (rd != 0) {
            regs[rd] = result;
            trace_rd = rd;
            trace_rd_val = result;
        }
        break;
    }
    case 0x0F: { // MISC-MEM (FENCE / FENCE.I / Zicbom CBO)
        if (funct3 == 0x0) {
            // FENCE — orders memory accesses.
            // The simulator has no store buffer or write-combining, so this is a
            // no-op.  All writes take effect immediately.
        } else if (funct3 == 0x1) {
            // FENCE.I — synchronise instruction and data streams.
            // In hardware this flushes the I-cache.  The simulator has no cache,
            // so all instruction fetches already see the latest memory state.
            // No-op.
        } else if (funct3 == 0x2) {
            // Zicbom CBO instruction — cache block operation.
            // The particular operation is encoded in imm[11:0] (bits[31:20]).
            // rs1 holds the effective address of the cache block to operate on.
            uint32_t cbo_op = (inst >> 20) & 0xFFF;
            (void)rs1; // base address — not needed in sim (no cache)
            switch (cbo_op) {
                case 0x000:
                    // cbo.inval rs1 — invalidate the cache line containing *rs1.
                    // No-op: simulator has no I-cache.
                    break;
                case 0x001:
                    // cbo.clean rs1 — write dirty data to memory for *rs1 line.
                    // No-op: simulator writes through immediately.
                    break;
                case 0x002:
                    // cbo.flush rs1 — write dirty data and invalidate *rs1 line.
                    // No-op: simulator writes through and has no cache.
                    break;
                default:
                    // Unknown CBO sub-operation — treat as illegal instruction.
                    std::cerr << "Unknown CBO op 0x" << std::hex << cbo_op
                              << " at PC 0x" << pc << std::endl;
                    take_trap(CAUSE_ILLEGAL_INSTRUCTION, inst);
                    untick_slaves();
                    inst_count--; csr_mcycle--; csr_minstret--;
                    return;
            }
        } else {
            // Unknown MISC-MEM funct3 — illegal instruction.
            std::cerr << "Unknown MISC-MEM funct3=0x" << std::hex << funct3
                      << " at PC 0x" << pc << std::endl;
            take_trap(CAUSE_ILLEGAL_INSTRUCTION, inst);
            untick_slaves();
            inst_count--; csr_mcycle--; csr_minstret--;
            return;
        }
        break;
    }
    case 0x73: { // System
        uint32_t csr_addr = (inst >> 20) & 0xFFF;
        uint32_t zimm =
            rs1; // Zero-extended immediate for CSR immediate instructions

        if (funct3 == 0) {
            // ECALL, EBREAK, MRET, WFI
            if (csr_addr == 0) {
                // ECALL — fires exception in EX stage (RTL never traces it)
                take_trap(CAUSE_ECALL_FROM_M, 0);
                untick_slaves(); // Undo the mtime increment — RTL does not advance mtime for exceptions
                inst_count--; csr_mcycle--; csr_minstret--; // Not retired — don't consume a trace slot
                return; // Do not log — RTL suppresses exception-causing instructions
            } else if (csr_addr == 1) {
                // EBREAK — fires exception in EX stage (RTL never traces it)
                take_trap(CAUSE_BREAKPOINT, pc);
                untick_slaves(); // Undo the mtime increment — RTL does not advance mtime for exceptions
                inst_count--; csr_mcycle--; csr_minstret--; // Not retired — don't consume a trace slot
                return; // Do not log — RTL suppresses exception-causing instructions
            } else if (csr_addr == 0x302) {
                // MRET - return from machine-mode trap
                // Per spec: MIE←MPIE, MPIE←1, MPP←least-privileged mode
                // Least-privileged mode is U (0) when U-mode is in MISA, else M (3)
                uint32_t mpie = (csr_mstatus >> 7) & 1;
                uint32_t mpp_reset = (csr_misa & (1 << 20)) ? 0 : 3; // U-mode if MISA.U set
                uint32_t new_mstatus =
                    (csr_mstatus & ~0x1888) | (mpie << 3) | (1 << 7) | (mpp_reset << 11);
                csr_mstatus = new_mstatus;
                trace_is_csr = true;
                trace_csr_num = 0x300;
                trace_rd = -1;
                trace_rd_val = new_mstatus;
                next_pc = csr_mepc;
            } else if (csr_addr == 0x105) {
                // WFI — Wait For Interrupt
                //
                // The RTL stalls WFI in EX until irq_pending fires, then flushes it
                // (never retires it).  mepc is set to WFI+4 so that MRET after the
                // handler returns to the instruction after WFI.
                //
                // Simulator model:
                //   1. Undo the inst/cycle counters incremented at top of step()
                //      (WFI does not retire in RTL).
                //   2. Advance pc to WFI+4 so that take_trap() stores WFI+4 in mepc.
                //   3. Spin: tick devices each iteration, check for a pending+enabled
                //      interrupt, then take it.  We accumulate mcycle ticks to model
                //      the time the core spends in the WFI stall.
                //   4. Return without logging (RTL never emits a trace entry for WFI).
                inst_count--;
                csr_minstret--;
                untick_slaves(); // undo the initial tick from the top of step()

                // Pre-advance pc so take_trap() saves mepc = WFI+4.
                pc = exec_pc + 4;

                // Mark that we are inside the WFI spin so take_trap() knows NOT
                // to set irq_before_wfi for interrupts that fire inside the spin
                // (those are the normal wakeup path).
                wfi_spin_active = true;

                // Spin until a machine-mode interrupt becomes pending and enabled.
                while (running) {
                    // Honour Ctrl-C even while the core is sleeping.
                    if (sigint_received) { running = false; break; }

                    // irq_before_wfi is set by take_trap() when an interrupt is
                    // taken OUTSIDE the WFI spin (i.e. the ISR already ran and the
                    // source was cleared before WFI was dispatched).  This mirrors
                    // the RTL irq_was_pending sticky flag: RISC-V allows WFI to be
                    // a NOP in that case, and we must not spin forever.
                    if (irq_before_wfi) { irq_before_wfi = false; break; }

                    tick_slaves();
                    csr_mcycle++;   // count idle cycles

                    // ── Update MIP from all interrupt sources ────────────────
                    {
                        uint32_t ps = 0;
                        if (uart->get_irq())  ps |= (1u << 1);
                        if (spi->get_irq())   ps |= (1u << 2);
                        if (i2c->get_irq())   ps |= (1u << 3);
                        if (dma->get_irq())   ps |= (1u << KV_PLIC_SRC_DMA);
                        if (gpio->get_irq())  ps |= (1u << KV_PLIC_SRC_GPIO);
                        if (timer->get_irq()) ps |= (1u << KV_PLIC_SRC_TIMER);
                        plic->update_irq_sources(ps);
                    }
                    if (clint->get_timer_interrupt())
                        csr_mip |= (1u << 7); else csr_mip &= ~(1u << 7);
                    if (clint->get_software_interrupt())
                        csr_mip |= (1u << 3); else csr_mip &= ~(1u << 3);
                    if (plic->get_external_interrupt())
                        csr_mip |= (1u << 11); else csr_mip &= ~(1u << 11);

                    // WFI wakes on any pending interrupt when MIE=1.
                    uint32_t mie_bit = (csr_mstatus >> 3) & 1;
                    if (!mie_bit) continue;     // Globally disabled — keep waiting

                    uint32_t pending = csr_mip & csr_mie;
                    if (!pending) continue;     // No enabled interrupt yet

                    // Take the highest-priority pending interrupt.
                    // take_trap() sets: pc = mtvec, mepc = exec_pc+4 (already set above),
                    //                   mcause, mtval, mstatus (MPIE=MIE, MIE=0, MPP=M).
                    if      (pending & (1u << 11)) take_trap(CAUSE_MACHINE_EXTERNAL_INT, 0);
                    else if (pending & (1u <<  7)) take_trap(CAUSE_MACHINE_TIMER_INT,    0);
                    else if (pending & (1u <<  3)) take_trap(CAUSE_MACHINE_SOFTWARE_INT, 0);
                    break;
                }
                wfi_spin_active = false; // we are no longer inside the WFI spin
                // WFI itself is not traced (matches RTL: instruction gets flushed, not retired).
                return;
            } // else if (csr_addr == 0x105) — WFI
        } else {
            // CSR instructions (Zicsr extension)
            //
            // Determine do_write BEFORE reading the CSR so we can raise
            // Illegal Instruction (no side-effects) if the CSR is read-only.
            bool do_write;
            switch (funct3) {
                case 0x1: case 0x5:  do_write = true;         break; // CSRRW, CSRRWI
                case 0x2: case 0x3:  do_write = (rs1 != 0);   break; // CSRRS, CSRRC
                case 0x6: case 0x7:  do_write = (zimm != 0);  break; // CSRRSI, CSRRCI
                default:             do_write = false;         break;
            }

            // Per RISC-V spec: CSR addr bits[11:10] == 2'b11 means read-only.
            // Any write attempt to such a CSR raises an Illegal Instruction exception.
            if (do_write && (csr_addr & 0xC00) == 0xC00) {
                take_trap(CAUSE_ILLEGAL_INSTRUCTION, inst);
                untick_slaves(); // Undo the slave tick — instruction not retired
                inst_count--; csr_mcycle--; csr_minstret--;
                return;
            }

            // Unknown CSR address — any access (read or write) raises Illegal Instruction.
            // Whitelist matches kv32_decoder.sv `inside {}` check.
            static const std::unordered_set<uint32_t> known_csrs = {
                CSR_MSTATUS, CSR_MISA,    CSR_MIE,      CSR_MTVEC,
                CSR_MSCRATCH, CSR_MEPC,  CSR_MCAUSE,   CSR_MTVAL,   CSR_MIP,
                CSR_MCYCLE,  CSR_MCYCLEH, CSR_MINSTRET, CSR_MINSTRETH,
                CSR_CYCLE,   CSR_TIME,    CSR_INSTRET,
                CSR_CYCLEH,  CSR_TIMEH,   CSR_INSTRETH,
                CSR_MVENDORID, CSR_MARCHID, CSR_MIMPID, CSR_MHARTID,
            };
            if (known_csrs.find(csr_addr) == known_csrs.end()) {
                take_trap(CAUSE_ILLEGAL_INSTRUCTION, inst);
                untick_slaves(); // Undo the slave tick — instruction not retired
                inst_count--; csr_mcycle--; csr_minstret--;
                return;
            }

            uint32_t csr_val = read_csr(csr_addr);
            uint32_t write_val = 0;

            switch (funct3) {
                case 0x1: write_val = regs[rs1];          break; // CSRRW
                case 0x2: write_val = csr_val | regs[rs1]; break; // CSRRS
                case 0x3: write_val = csr_val & ~regs[rs1]; break; // CSRRC
                case 0x5: write_val = zimm;               break; // CSRRWI
                case 0x6: write_val = csr_val | zimm;     break; // CSRRSI
                case 0x7: write_val = csr_val & ~zimm;    break; // CSRRCI
            }

            if (rd != 0) {
                regs[rd] = csr_val;
                trace_rd = rd;
                trace_rd_val = csr_val;
            }

            if (do_write) {
                write_csr(csr_addr, write_val);
                trace_is_csr = true;
                trace_csr_num = csr_addr;
                trace_rd_val = read_csr(csr_addr); // Show the value after write/masking
            }
        }
        break;
    }
    case 0x2F: { // AMO (Atomic)
        uint32_t addr = regs[rs1];
        uint32_t loaded = read_mem(addr, 4);
        uint32_t result = loaded;
        uint32_t store_val = regs[rs2];

        switch (funct3) {
            case 0x2: { // Word operations
                uint32_t funct5 = (funct7 >> 2) & 0x1F;
                switch (funct5) {
                    case 0x02:
                        write_mem(addr, store_val, 4);
                        break; // LR.W (just load)
                    case 0x03:
                        write_mem(addr, store_val, 4);
                        result = 0;
                        break; // SC.W
                    case 0x01:
                        result = loaded;
                        write_mem(addr, store_val, 4);
                        break; // AMOSWAP.W
                    case 0x00:
                        result = loaded;
                        write_mem(addr, loaded + store_val, 4);
                        break; // AMOADD.W
                    case 0x04:
                        result = loaded;
                        write_mem(addr, loaded ^ store_val, 4);
                        break; // AMOXOR.W
                    case 0x0C:
                        result = loaded;
                        write_mem(addr, loaded & store_val, 4);
                        break; // AMOAND.W
                    case 0x08:
                        result = loaded;
                        write_mem(addr, loaded | store_val, 4);
                        break; // AMOOR.W
                    case 0x10:
                        result = loaded;
                        write_mem(addr,
                                  ((int32_t)loaded < (int32_t)store_val) ? loaded
                                                                         : store_val,
                                  4);
                        break; // AMOMIN.W
                    case 0x14:
                        result = loaded;
                        write_mem(addr,
                                  ((int32_t)loaded > (int32_t)store_val) ? loaded
                                                                         : store_val,
                                  4);
                        break; // AMOMAX.W
                    case 0x18:
                        result = loaded;
                        write_mem(addr, (loaded < store_val) ? loaded : store_val, 4);
                        break; // AMOMINU.W
                    case 0x1C:
                        result = loaded;
                        write_mem(addr, (loaded > store_val) ? loaded : store_val, 4);
                        break; // AMOMAXU.W
                }
                break;
            }
        }
        if (rd != 0) {
            regs[rd] = result;
            trace_rd = rd;
            trace_rd_val = result;
        }
        // Note: AMO instructions do both read and write, but spike only shows
        // the result register
        break;
    }
    default:
        std::cerr << "Unknown instruction: 0x" << std::hex << inst
                  << " at PC 0x" << pc << std::endl;
        // Fire illegal instruction exception (cause=2, mtval=instruction word).
        // Do NOT log a trace entry — RTL also suppresses the exception-causing
        // instruction from the trace (wb_exception gates retire_instr).
        take_trap(CAUSE_ILLEGAL_INSTRUCTION, inst);
        untick_slaves(); // Undo the mtime increment — RTL does not advance mtime for exceptions
        inst_count--; csr_mcycle--; csr_minstret--; // Not retired — don't consume a trace slot
        return;
    }

    regs[0] = 0; // x0 is always 0

    // Exception-causing instructions are not logged (spike/RTL don't emit trace for them).
    // Note: no counter adjustment or untick here — counters/mtime stay consistent
    // with the trap handler's view (misaligned exceptions don't suppress mtime/minstret).
    if (exception_occurred) {
        // exception_occurred is set by read_mem/write_mem for:
        //   cause 5 (load access fault)  – load is NOT in the RTL trace (WB stalls
        //                                   until the R response, wb_exception blocks retirement)
        //   cause 6 (store misaligned)   – store is NOT in the RTL trace (EX-stage exception)
        //   cause 7 (store access fault) – store is NOT in the RTL trace; the RTL
        //                                   takes the exception before retiring the store
        //                                   (the B-channel SLVERR blocks retirement).
        // Faulting instructions are never logged — the trace only contains committed instructions.
        pc = exception_pc;
        exception_occurred = false;
    } else if (next_pc & 0x1) {
        // Misaligned instruction-fetch (branch/jal taken to misaligned address)
        // With RVC, 2-byte alignment is required; 1-byte (odd) alignment is always illegal.
        uint32_t mie_bit = (csr_mstatus >> 3) & 1;
        csr_mstatus = (csr_mstatus & ~0x1888) | (mie_bit << 7) | (3 << 11);
        write_csr(CSR_MCAUSE, 0);
        write_csr(CSR_MTVAL, next_pc); // Misaligned target address
        write_csr(CSR_MEPC, exec_pc);
        uint32_t mtvec = read_csr(CSR_MTVEC);
        pc = mtvec & ~0x3;
    } else {
        // Normal retirement: log trace entry and advance PC
        log_commit(exec_pc, orig_inst, trace_rd, trace_rd_val, trace_has_mem,
                       trace_mem_addr, trace_mem_val, trace_is_store, trace_is_csr,
                       trace_csr_num);
        pc = next_pc;
    }

    // Safety check
    if (inst_count > 100000000) {
        std::cerr << "Instruction limit exceeded" << std::endl;
        running = false;
    }
}

// Load ELF file
bool KV32Simulator::load_elf(const char *filename) {
    std::ifstream file(filename, std::ios::binary);
    if (!file.is_open()) {
        std::cerr << "Failed to open ELF file: " << filename << std::endl;
        return false;
    }
    Elf32_Ehdr ehdr;
    file.read((char *)&ehdr, sizeof(ehdr));

    if (memcmp(ehdr.e_ident, ELFMAG, SELFMAG) != 0) {
        std::cerr << "Not a valid ELF file" << std::endl;
        return false;
    }

    // Set entry point
    pc = ehdr.e_entry;

    // Load program headers
    file.seekg(ehdr.e_phoff);
    for (int i = 0; i < ehdr.e_phnum; i++) {
        Elf32_Phdr phdr;
        size_t phdr_pos = ehdr.e_phoff + i * sizeof(Elf32_Phdr);
        file.seekg(phdr_pos);
        file.read((char *)&phdr, sizeof(phdr));

        if (phdr.p_type == PT_LOAD) {
            // Check if address is within our memory range
            if (phdr.p_paddr >= mem_base &&
                phdr.p_paddr < mem_base + mem_size) {
                uint32_t offset = phdr.p_paddr - mem_base;
                if (offset + phdr.p_memsz <= mem_size) {
                    file.seekg(phdr.p_offset);
                    std::vector<char> segment(phdr.p_filesz);
                    file.read(segment.data(), phdr.p_filesz);
                    for (uint32_t b = 0; b < phdr.p_filesz; ++b) {
                        memory->write(offset + b, (uint8_t)segment[b], 1);
                    }
                    // Zero out BSS
                    if (phdr.p_memsz > phdr.p_filesz) {
                        for (uint32_t b = phdr.p_filesz; b < phdr.p_memsz; ++b) {
                            memory->write(offset + b, 0, 1);
                        }
                    }
                }
            }
        }
    }

    // Find tohost symbol
    file.seekg(ehdr.e_shoff);
    for (int i = 0; i < ehdr.e_shnum; i++) {
        Elf32_Shdr shdr;
        file.read((char *)&shdr, sizeof(shdr));

        if (shdr.sh_type == SHT_SYMTAB) {
            // Read symbol table
            std::vector<char> strtab;
            Elf32_Shdr strtab_hdr;
            file.seekg(ehdr.e_shoff + shdr.sh_link * sizeof(Elf32_Shdr));
            file.read((char *)&strtab_hdr, sizeof(strtab_hdr));
            strtab.resize(strtab_hdr.sh_size);
            file.seekg(strtab_hdr.sh_offset);
            file.read(strtab.data(), strtab_hdr.sh_size);

            file.seekg(shdr.sh_offset);
            for (size_t j = 0; j < shdr.sh_size / sizeof(Elf32_Sym); j++) {
                Elf32_Sym sym;
                file.read((char *)&sym, sizeof(sym));

                if (sym.st_name < strtab.size()) {
                    std::string name = &strtab[sym.st_name];
                    if (name == "tohost") {
                        tohost_addr = sym.st_value;
                    } else if (name == "begin_signature") {
                        signature_start = sym.st_value;
                    } else if (name == "end_signature") {
                        signature_end = sym.st_value;
                    }
                }
            }
        }
    }

    file.close();
    return true;
}

void KV32Simulator::run() {
    if (gdb_enabled) {
        std::cout << "GDB stub enabled, waiting for GDB connection..." << std::endl;
        gdb_context_t* gdb = (gdb_context_t*)gdb_ctx;

        // Setup callbacks
        gdb_callbacks_t callbacks = {
            .read_reg = gdb_read_reg,
            .write_reg = gdb_write_reg,
            .read_mem = gdb_read_mem,
            .write_mem = gdb_write_mem,
            .get_pc = gdb_get_pc,
            .set_pc = gdb_set_pc,
            .single_step = gdb_single_step,
            .is_running = gdb_is_running
        };

        // Wait for GDB to connect
        if (gdb_stub_accept(gdb) < 0) {
            std::cerr << "Failed to accept GDB connection" << std::endl;
            return;
        }

        std::cout << "GDB connected, starting debug session" << std::endl;

        // Start in stopped state, wait for GDB to issue continue/step
        gdb->should_stop = true;

        // GDB debug loop
        while (running) {
            // Process GDB commands
            int result = gdb_stub_process(gdb, this, &callbacks);
            if (result < 0) {
                std::cout << "GDB disconnected" << std::endl;
                break;
            }

            // If GDB issued continue/step command (result == 1), execute
            if (result == 1 && !gdb->should_stop) {
                // For single-step, execute just one instruction
                if (gdb->single_step) {
                    step();
                    gdb->should_stop = true;
                    gdb->single_step = false;
                    gdb_stub_send_stop_signal(gdb, 5); // SIGTRAP after single step
                }
                // For continue, keep executing until breakpoint or exit
                else {
                    while (running && !gdb->should_stop) {
                        step();

                        // Check if watchpoint was hit during execution (set by read_mem/write_mem)
                        if (gdb->should_stop) {
                            gdb_stub_send_stop_signal(gdb, 5); // SIGTRAP
                            break;
                        }

                        // Check for breakpoint at new PC after execution
                        if (gdb_stub_check_breakpoint(gdb, pc)) {
                            // Hit breakpoint, stop and notify GDB
                            gdb->should_stop = true;
                            gdb_stub_send_stop_signal(gdb, 5); // SIGTRAP
                            std::cout << "Breakpoint hit at 0x" << std::hex << pc << std::endl;
                            break;
                        }

                        // Check instruction limit (if set)
                        if (max_instructions > 0 && inst_count >= max_instructions) {
                            std::cout << "\n[LIMIT] Reached instruction limit: " << std::dec << inst_count << std::endl;
                            running = false;
                            break;
                        }
                    }
                }
            } else {
                // CPU is halted, wait briefly to avoid busy waiting
                usleep(1000); // 1ms
            }
        }
    } else {
        // Normal execution without GDB
        while (running) {
            // Check for SIGINT
            if (sigint_received) {
                std::cerr << "\n*** SIGINT received: dumping registers and exiting ***" << std::endl;
                dump_registers(this);
                exit_code = 1;
                break;
            }

            step();

            // Check instruction limit (if set)
            if (max_instructions > 0 && inst_count >= max_instructions) {
                std::cout << "\n[LIMIT] Reached instruction limit: " << std::dec << inst_count << std::endl;
                break;
            }
        }
    }

    std::cout << "Instructions executed: " << std::dec << inst_count
              << std::endl;

    // Write signature file if enabled
    write_signature();
}

// Compute the MISA value from an ISA string such as "rv32ima" or "rv32imac_zicsr".
// Always sets MXL=1 (RV32) plus S and U mode support.
// Extension letters (a-z) between the "rv32" prefix and the first '_' are mapped
// directly to MISA bits: bit = letter - 'a'.
static uint32_t compute_misa(const char *isa) {
    uint32_t misa = (1u << 30);             // MXL=1 → RV32
    misa |= (1u << 20) | (1u << 18);       // U-mode (bit 20), S-mode (bit 18)

    // Skip optional "rv32" prefix
    const char *p = isa;
    if (strncmp(p, "rv32", 4) == 0) p += 4;

    // Consume single-letter extension characters until '_' or NUL
    while (*p && *p != '_') {
        char c = (char)tolower((unsigned char)*p);
        if (c >= 'a' && c <= 'z')
            misa |= (1u << (c - 'a'));
        p++;
    }
    return misa;
}

void print_usage(const char *prog) {
    std::cerr << "Usage: " << prog << " [options] <elf_file>" << std::endl;
    std::cerr << "Options:" << std::endl;
    std::cerr << "  --isa=<name>         Specify ISA (default: rv32imac)"
              << std::endl;
    std::cerr << "                       Supported: rv32ima, rv32imac, rv32ima_zicsr, rv32imac_zicsr"
              << std::endl;
    std::cerr
        << "  --trace              Enable Spike-format trace logging (alias "
           "for --log-commits)"
        << std::endl;
    std::cerr << "  --log-commits        Enable Spike-format trace logging"
              << std::endl;
    std::cerr << "  --rtl-trace          Enable RTL-format trace logging"
              << std::endl;
    std::cerr
        << "  --log=<file>         Specify trace log output file (default: "
           "sim_trace.txt)"
        << std::endl;
    std::cerr << "  +signature=<file>    Write signature to file (RISCOF compatibility)"
              << std::endl;
    std::cerr << "  +signature-granularity=<n>  Signature granularity in bytes (1, 2, or 4, default: 4)"
              << std::endl;
    std::cerr << "  -m<base>:<size>      Specify memory range (e.g., "
                 "-m0x80000000:0x200000)"
              << std::endl;
    std::cerr
        << "                       Default: -m0x80000000:0x200000 (2MB at "
           "0x80000000)"
        << std::endl;
    std::cerr << "  --instructions=<n>   Limit execution to N instructions (0 = no limit)"
              << std::endl;
    std::cerr << "  --gdb                Enable GDB stub for remote debugging"
              << std::endl;
    std::cerr << "  --gdb-port=<port>    Specify GDB port (default: 3333)"
              << std::endl;
    std::cerr << "Examples:" << std::endl;
    std::cerr << "  " << prog << " program.elf" << std::endl;
    std::cerr << "  " << prog << " --log-commits --log=output.log program.elf"
              << std::endl;
    std::cerr << "  " << prog << " --rtl-trace --log=rtl_trace.txt program.elf"
              << std::endl;
    std::cerr << "  " << prog
              << " --log-commits -m0x80000000:0x200000 program.elf"
              << std::endl;
    std::cerr << "  " << prog << " --gdb --gdb-port=3333 program.elf"
              << std::endl;
    std::cerr << "  " << prog << " +signature=output.sig +signature-granularity=4 test.elf"
              << std::endl;
}

bool parse_hex(const char *str, uint32_t &value) {
    char *endptr;
    if (strncmp(str, "0x", 2) == 0 || strncmp(str, "0X", 2) == 0) {
        value = strtoul(str + 2, &endptr, 16);
    } else {
        value = strtoul(str, &endptr, 16);
    }
    return (*endptr == '\0' || *endptr == ':');
}

int main(int argc, char *argv[]) {
    const char *elf_file = nullptr;
    const char *log_file = "sim_trace.txt";
    const char *signature_file = nullptr;
    uint32_t signature_granularity = 4;
    bool trace_enabled = false;
    bool rtl_trace_format = false;  // Use RTL trace format instead of Spike
    uint32_t mem_base = MEM_BASE;
    uint32_t mem_size = MEM_SIZE;
    const char *isa_name = "rv32ima";
    bool gdb_enabled = false;
    int gdb_port = GDB_DEFAULT_PORT;
    uint64_t max_instructions = 0;  // 0 = no limit

    // Parse command line arguments
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "--isa=", 6) == 0) {
            isa_name = argv[i] + 6;
            // Accept rv32ima, rv32imac, or rv32ima_zicsr variants
            if (strcmp(isa_name, "rv32ima")         != 0 &&
                strcmp(isa_name, "rv32imac")        != 0 &&
                strcmp(isa_name, "rv32ima_zicsr")   != 0 &&
                strcmp(isa_name, "rv32imac_zicsr")  != 0) {
                std::cerr << "Error: Unsupported ISA '" << isa_name << "'"
                          << std::endl;
                std::cerr << "Supported ISAs: rv32ima, rv32imac, rv32ima_zicsr, rv32imac_zicsr"
                          << std::endl;
                return 1;
            }
        } else if (strcmp(argv[i], "--log-commits") == 0 ||
                   strcmp(argv[i], "--trace") == 0) {
            trace_enabled = true;
        } else if (strcmp(argv[i], "--rtl-trace") == 0) {
            trace_enabled = true;
            rtl_trace_format = true;
        } else if (strncmp(argv[i], "--log=", 6) == 0) {
            log_file = argv[i] + 6;
        } else if (strncmp(argv[i], "+signature=", 11) == 0) {
            signature_file = argv[i] + 11;
        } else if (strncmp(argv[i], "+signature-granularity=", 23) == 0) {
            char *endptr;
            signature_granularity = strtoul(argv[i] + 23, &endptr, 10);
            if (*endptr != '\0' || (signature_granularity != 1 &&
                signature_granularity != 2 && signature_granularity != 4)) {
                std::cerr << "Invalid signature granularity (must be 1, 2, or 4): "
                          << (argv[i] + 23) << std::endl;
                return 1;
            }
        } else if (strncmp(argv[i], "--instructions=", 15) == 0) {
            // Parse instruction limit
            char *endptr;
            max_instructions = strtoull(argv[i] + 15, &endptr, 10);
            if (*endptr != '\0') {
                std::cerr << "Invalid instruction limit: " << (argv[i] + 15) << std::endl;
                return 1;
            }
        } else if (strcmp(argv[i], "--gdb") == 0) {
            gdb_enabled = true;
        } else if (strncmp(argv[i], "--gdb-port=", 11) == 0) {
            // Parse GDB port (decimal)
            char *endptr;
            long port_val = strtol(argv[i] + 11, &endptr, 10);
            if (*endptr != '\0' || port_val <= 0 || port_val > 65535) {
                std::cerr << "Invalid GDB port (must be 1-65535): " << (argv[i] + 11) << std::endl;
                return 1;
            }
            gdb_port = port_val;
        } else if (strncmp(argv[i], "-m", 2) == 0) {
            // Parse memory range: -m0x80000000:0x200000
            const char *range = argv[i] + 2;
            const char *colon = strchr(range, ':');
            if (colon) {
                char base_str[32];
                strncpy(base_str, range, colon - range);
                base_str[colon - range] = '\0';

                if (!parse_hex(base_str, mem_base)) {
                    std::cerr << "Invalid memory base address: " << base_str
                              << std::endl;
                    return 1;
                }
                if (!parse_hex(colon + 1, mem_size)) {
                    std::cerr << "Invalid memory size: " << (colon + 1)
                              << std::endl;
                    return 1;
                }
            } else {
                std::cerr << "Invalid memory range format. Use -m<base>:<size>"
                          << std::endl;
                return 1;
            }
        } else if (argv[i][0] == '-') {
            std::cerr << "Unknown option: " << argv[i] << std::endl;
            print_usage(argv[0]);
            return 1;
        } else {
            elf_file = argv[i];
        }
    }

    if (!elf_file) {
        std::cerr << "Error: No ELF file specified" << std::endl;
        print_usage(argv[0]);
        return 1;
    }

    // Setup SIGINT handler
    std::signal(SIGINT, handle_sigint);

    std::cout << "=== RV32IMAC (Compressed) Software Simulator ===" << std::endl;
    if (trace_enabled) {
        std::cout << "Trace: enabled -> " << log_file << std::endl;
    }
    if (signature_file) {
        std::cout << "Signature: enabled -> " << signature_file
                  << " (granularity=" << signature_granularity << ")" << std::endl;
    }
    if (gdb_enabled) {
        std::cout << "GDB: enabled on port " << std::dec << gdb_port
                  << std::endl;
    }
    std::cout << std::endl;

    KV32Simulator sim(mem_base, mem_size);
    g_sim_instance = &sim;

    // Override misa to match the requested ISA (sets the C bit for rv32imac, etc.)
    sim.csr_misa = compute_misa(isa_name);

    if (trace_enabled) {
        sim.enable_trace(log_file, rtl_trace_format);
    }

    if (signature_file) {
        sim.enable_signature(signature_file, signature_granularity);
    }

    // Set instruction limit
    sim.max_instructions = max_instructions;

    // Initialize GDB stub if enabled
    if (gdb_enabled) {
        gdb_context_t* gdb_ctx = new gdb_context_t();
        memset(gdb_ctx, 0, sizeof(gdb_context_t));

        if (gdb_stub_init(gdb_ctx, gdb_port) < 0) {
            std::cerr << "Failed to initialize GDB stub" << std::endl;
            delete gdb_ctx;
            return 1;
        }

        sim.gdb_ctx = gdb_ctx;
        sim.gdb_enabled = true;
    }

    if (!sim.load_elf(elf_file)) {
        return 1;
    }

    sim.run();

    return sim.exit_code;
}
