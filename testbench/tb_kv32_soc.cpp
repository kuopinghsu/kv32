// ============================================================================
// File: tb_kv32_soc.cpp
// Project: KV32 RISC-V Processor
// Description: Verilator C++ Testbench Driver
//
// Main testbench driver that controls simulation, loads ELF files,
// generates instruction traces, and manages waveform dumps.
// ============================================================================

#include <verilated.h>
#include <verilated_fst_c.h>
#if VM_TRACE_VCD
#include <verilated_vcd_c.h>
#endif
#if VM_COVERAGE
#include <verilated_cov.h>
#endif
#include "Vtb_kv32_soc.h"
#include "Vtb_kv32_soc__Dpi.h"
#include "elfloader.h"
#include "../sim/riscv-dis.h"
#include <iostream>
#include <iomanip>
#include <fstream>
#include <sstream>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <csignal>

#define HAVE_CHRONO

#ifdef HAVE_CHRONO
#include <chrono>
#endif

// Clock period in ns
#define CLK_PERIOD 20

// Global time variable for Verilator $time
vluint64_t main_time = 0;

// Required by Verilator for $time
double sc_time_stamp() {
    return main_time;
}

// DPI-C function declarations for AXI memory statistics and access
extern "C" {
    extern int mem_get_stat_ar_requests();
    extern int mem_get_stat_r_responses();
    extern int mem_get_stat_aw_requests();
    extern int mem_get_stat_w_data();
    extern int mem_get_stat_w_expected();
    extern int mem_get_stat_b_responses();
    extern int mem_get_stat_max_outstanding_reads();
    extern int mem_get_stat_max_outstanding_writes();
    // Memory byte access (offset from base address)
    extern char mem_read_byte(int addr);
}

// Exit request handling
static volatile sig_atomic_t sigint_received = 0;
static volatile int exit_requested = 0;
static volatile int exit_code_value = 0;

// DPI-C export function called from axi_magic when exit is requested
extern "C" void sim_request_exit(int exit_code) {
    exit_requested = 1;
    exit_code_value = exit_code;
}

static void handle_sigint(int) {
    sigint_received = 1;
}

// Debug macros
#ifdef DEBUG
#define DEBUG1(fmt, ...) do { \
    if (DEBUG >= 1) { \
        fprintf(stderr, "[DEBUG] " fmt "\n", ##__VA_ARGS__); \
    } \
} while(0)

#define DEBUG2(fmt, ...) do { \
    if (DEBUG >= 2) { \
        fprintf(stderr, "[DEBUG] " fmt "\n", ##__VA_ARGS__); \
    } \
} while(0)
#else
#define DEBUG1(fmt, ...)
#define DEBUG2(fmt, ...)
#endif

// Helper function to get register name
static std::string get_reg_name(uint32_t reg) {
    const char* names[] = {
        "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
        "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
        "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
        "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"
    };
    if (reg < 32) return names[reg];
    return "unknown";
}

static void dump_registers() {
    svScope scope = svGetScopeFromName("TOP.tb_kv32_soc");
    if (!scope) {
        scope = svGetScopeFromName("tb_kv32_soc");
    }
    if (scope) {
        svSetScope(scope);
    }

    // Get PC from WB stage
    svBitVecVal pc_wb[1], instr_wb[1], alu_result_wb[1], mem_data_wb[1];
    svBitVecVal store_data_wb[1], rd_addr_wb[1], csr_op_wb[1], csr_addr_wb[1], csr_rdata_wb[1];
    svBitVecVal csr_wdata_wb[1], csr_zimm_wb[1], mstatus_wb_sigint[1];
    svBit wb_valid, reg_we_wb, mem_read_wb, mem_write_wb, retire_instr;

    get_wb_signals(&wb_valid, &retire_instr, pc_wb, instr_wb, rd_addr_wb,
                   &reg_we_wb, &mem_read_wb, &mem_write_wb,
                   alu_result_wb, mem_data_wb, store_data_wb,
                   csr_wdata_wb, csr_zimm_wb, csr_op_wb, csr_addr_wb, csr_rdata_wb,
                   mstatus_wb_sigint);

    std::cout << "\n=== Register Dump (SIGINT) ===" << std::endl;
    std::cout << "PC  : 0x" << std::hex << std::setfill('0') << std::setw(8) << pc_wb[0] << std::dec << std::endl;

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
            get_reg_name(r0).c_str(), get_reg_value(r0),
            get_reg_name(r1).c_str(), get_reg_value(r1),
            get_reg_name(r2).c_str(), get_reg_value(r2),
            get_reg_name(r3).c_str(), get_reg_value(r3)
        );
        std::cout << line << std::endl;
    }
    std::cout << "==========================================\n" << std::endl;
}

// DPI export function to provide tohost address to RTL
extern "C" int get_tohost_addr() {
    return g_tohost_addr;
}

// Trace dumping function
static void dump_instruction_trace(
    Vtb_kv32_soc* dut,
    std::ofstream& trace_file,
    RiscvDisassembler* disasm,
    uint64_t& instr_count,
    uint64_t cycle_num,
    bool& debug_printed
) {
    // Set DPI scope - use the actual instance path
    svScope scope = svGetScopeFromName("TOP.tb_kv32_soc");
    if (!scope) {
        // Try alternate scope name
        scope = svGetScopeFromName("tb_kv32_soc");
    }
    if (scope) {
        svSetScope(scope);
    }

    // Check if writeback is valid (trace at WB stage for accurate data)
    svBit wb_valid_val = 0;
    try {
        svBitVecVal pc_wb[1], instr_wb[1], alu_result_wb[1], mem_data_wb[1];
        svBitVecVal store_data_wb[1], rd_addr_wb[1], csr_op_wb[1], csr_addr_wb[1], csr_rdata_wb[1];
        svBitVecVal csr_wdata_wb[1], csr_zimm_wb[1], mstatus_wb[1];
        svBit reg_we_wb, mem_read_wb, mem_write_wb;
        svBit retire_instr;

        dut->get_wb_signals(&wb_valid_val, &retire_instr, pc_wb, instr_wb, rd_addr_wb,
                    &reg_we_wb, &mem_read_wb, &mem_write_wb,
                    alu_result_wb, mem_data_wb, store_data_wb,
                    csr_wdata_wb, csr_zimm_wb, csr_op_wb, csr_addr_wb, csr_rdata_wb,
                    mstatus_wb);

        static bool last_valid = false;
        static uint32_t last_pc = 0;
        static uint32_t last_instr = 0;

        // ── Pending-store buffer ────────────────────────────────────────────
        // When a FENCE follows a store in the MEM stage, the pipeline stalls
        // until the store-buffer B-channel response arrives.  Nothing else can
        // retire during this window.  We hold the store's trace line here and
        // only commit it to the file when the B-channel returns OK; on SLVERR
        // we discard it so the trace matches the sw-simulator's precise-
        // exception behaviour (faulting store must not appear as committed).
        static std::string pstore_line;
        static bool        pstore_has   = false;
        static uint64_t    pstore_count = 0;   // instr_count before this store
        static bool        pstore_lv    = false;
        static uint32_t    pstore_lp    = 0;
        static uint32_t    pstore_li    = 0;
        // ───────────────────────────────────────────────────────────────────

        // Flush pending store once the B-channel response has arrived.
        // This must run even when nothing is retiring (FENCE stall cycles).
        if (pstore_has) {
            svBit resp_valid, resp_error, fence_in_mem_unused;
            dut->get_store_resp(&resp_valid, &resp_error, &fence_in_mem_unused);
            if (resp_valid) {
                if (!resp_error) {
                    // Store completed OK — emit the buffered line
                    trace_file << pstore_line << std::endl;
                } else {
                    // Store faulted (SLVERR) — discard and roll back state
                    instr_count = pstore_count;
                    last_valid  = pstore_lv;
                    last_pc     = pstore_lp;
                    last_instr  = pstore_li;
                }
                pstore_has = false;
            }
        }

        if (!wb_valid_val || !retire_instr) {
            return;
        }

        // Extract values (svBitVecVal is essentially uint32_t)
        uint32_t pc = pc_wb[0];
        uint32_t instr = instr_wb[0];

        if (last_valid && pc == last_pc && instr == last_instr) {
            return;
        }

        // Save dedup/count state before this instruction's update.
        // Used to roll back if this turns out to be a SLVERR store.
        const uint64_t prior_count = instr_count;  // before ++
        const bool     prior_lv    = last_valid;
        const uint32_t prior_lp    = last_pc;
        const uint32_t prior_li    = last_instr;

        instr_count++;
        last_valid = true;
        last_pc = pc;
        last_instr = instr;
        uint8_t rd_addr = rd_addr_wb[0] & 0x1F;
        uint32_t alu_res = alu_result_wb[0];
        uint32_t mem_data = mem_data_wb[0];
        uint32_t store_data = store_data_wb[0];

        uint8_t csr_op = csr_op_wb[0] & 0x7;
        uint16_t csr_addr = csr_addr_wb[0] & 0xFFF;
        uint32_t csr_rdata = csr_rdata_wb[0];
        uint32_t csr_wdata = csr_wdata_wb[0];
        uint32_t csr_zimm = csr_zimm_wb[0] & 0x1F;
        uint32_t mstatus = mstatus_wb[0];
        bool is_csr = (csr_op != 0);
        bool is_mret = (instr == 0x30200073);

        DEBUG2("Cycle %llu: Instr %llu @ PC=0x%08x instr=0x%08x rd=%d mem_w=%d mem_r=%d",
             cycle_num, instr_count, pc, instr, rd_addr, mem_write_wb, mem_read_wb);

        if (mem_write_wb) {
            DEBUG2("Cycle %llu: Memory WRITE addr=0x%08x", cycle_num, alu_res);
        }
        if (mem_read_wb) {
            DEBUG2("Cycle %llu: Memory READ addr=0x%08x", cycle_num, alu_res);
        }

        // Build trace line into string stream for alignment
        std::ostringstream line_stream;
        line_stream << instr_count << " "
                    << "0x" << std::hex << std::setfill('0') << std::setw(8) << pc << " "
                    << "(0x" << std::setw(8) << instr << ")";

        // Write register write (if any)
        if (reg_we_wb && rd_addr != 0) {
            uint32_t rd_data;
            if (is_csr) {
                // For CSR instructions, rd gets the old CSR value (before write)
                rd_data = csr_rdata;
            } else {
                rd_data = mem_read_wb ? mem_data : alu_res;
            }
            line_stream << " " << get_reg_name(rd_addr)
                        << " 0x" << std::setw(8) << rd_data;
        }

        // Write memory operation info for current instruction (at WB stage)
        if (mem_write_wb) {
            line_stream << " mem 0x" << std::setw(8) << alu_res
                        << " 0x" << std::setw(8) << store_data;
        } else if (mem_read_wb) {
            line_stream << " mem 0x" << std::setw(8) << alu_res;
        }

        // For CSR instructions with rd=zero, show CSR name (matches simulator format)
        if (is_csr && rd_addr == 0) {
            const char* csr_name = "";
            switch (csr_addr) {
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
            case 0xb80: csr_name = "mcycleh"; break;
            case 0xb82: csr_name = "minstreth"; break;
            case 0xc00: csr_name = "cycle"; break;
            case 0xc01: csr_name = "time"; break;
            case 0xc02: csr_name = "instret"; break;
            case 0xc80: csr_name = "cycleh"; break;
            case 0xc81: csr_name = "timeh"; break;
            case 0xc82: csr_name = "instreth"; break;
            default: csr_name = "unknown"; break;
            }
            uint32_t csr_result = csr_rdata;
            switch (csr_op) {
            case 0x1: csr_result = csr_wdata; break;                          // CSRRW
            case 0x2: csr_result = csr_rdata | csr_wdata; break;              // CSRRS
            case 0x3: csr_result = csr_rdata & ~csr_wdata; break;             // CSRRC
            case 0x5: csr_result = csr_zimm; break;                           // CSRRWI
            case 0x6: csr_result = csr_rdata | csr_zimm; break;               // CSRRSI
            case 0x7: csr_result = csr_rdata & ~csr_zimm; break;              // CSRRCI
            default: break;
            }
            line_stream << " c" << std::setfill('0') << std::setw(3) << std::hex << csr_addr
                       << "_" << csr_name
                       << " 0x" << std::setw(8) << csr_result;
        }

        // mret implicitly updates mstatus (MIE=MPIE, MPIE=1) - emit as CSR write
        if (is_mret) {
            line_stream << " c300_mstatus"
                       << " 0x" << std::setfill('0') << std::setw(8) << std::hex << mstatus;
        }

        // Get base line for alignment
        std::string base_line = line_stream.str();

        // Add disassembly comment aligned at column 72 (so "; " starts at column 72)
        std::string disasm_str = disasm->disassemble(instr, pc);
        int padding_needed = 72 - base_line.length();
        if (padding_needed < 2) padding_needed = 2;  // At least 2 spaces

        // For store instructions: check whether a FENCE is currently in the
        // MEM stage.  If so, the pipeline will stall until the B-channel
        // response arrives, guaranteeing no other instruction can retire in
        // the meantime.  Buffer this store's line and decide later whether to
        // commit it (B-channel OK) or discard it (B-channel SLVERR).
        if (mem_write_wb) {
            svBit fence_in_mem, _rv, _re;
            dut->get_store_resp(&_rv, &_re, &fence_in_mem);
            if (fence_in_mem) {
                // A FENCE is in MEM right behind this store.  The pipeline will
                // stall until the B-channel response arrives, so nothing else
                // can retire before we decide to commit or discard this entry.
                pstore_count = prior_count;
                pstore_lv    = prior_lv;
                pstore_lp    = prior_lp;
                pstore_li    = prior_li;
                pstore_line  = base_line + std::string(padding_needed, ' ') + "; " + disasm_str;
                pstore_has   = true;
                return; // do not write to trace file yet
            }
        }

        trace_file << base_line << std::string(padding_needed, ' ') << "; " << disasm_str << std::endl;
    } catch (...) {
        if (!debug_printed) {
            std::cerr << "WARNING: DPI call failed at cycle " << cycle_num << std::endl;
            debug_printed = true;
        }
    }
}

// Parse command line arguments
static bool enable_trace = false;
static bool enable_wave = false;
static bool enable_wave_vcd = false;
static bool show_help = false;
static uint64_t max_instructions = 0;  // 0 = no limit
static std::string elf_file = "";
static std::string trace_log_file = "rtl_trace.txt";
static std::string signature_file = "";
static int sig_granularity = 4;  // bytes per signature entry (1, 2, or 4)

void print_help(const char* prog_name) {
    std::cout << "Usage: " << prog_name << " [options] <elf_file>\n";
    std::cout << "Options:\n";
    std::cout << "  --help                        Show this help message\n";
    std::cout << "  --wave=[fst|vcd]              Dump fst or vcd waveform\n";
    std::cout << "  --trace                       Enable Spike-format trace logging (alias for --log-commits)\n";
    std::cout << "  --log-commits                 Enable Spike-format trace logging\n";
    std::cout << "  --log=<file>                  Specify trace log output file (default: rtl_trace.txt)\n";
    std::cout << "  +signature=<file>             Write signature to file (RISCOF compatibility)\n";
    std::cout << "  +signature-granularity=<n>    Signature granularity in bytes (1, 2, or 4, default: 4)\n";
    std::cout << "  -m<base>:<size>               Specify memory range (e.g., -m0x80000000:0x200000)\n";
    std::cout << "                                Default: -m0x80000000:0x200000 (2MB at 0x80000000)\n";
    std::cout << "  --instructions=<n>            Limit execution to N instructions (0 = no limit)\n";
    std::cout << "\n";
}

void parse_args(int argc, char** argv) {
    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        if (arg == "--help") {
            show_help = true;
        } else if (arg == "--trace" || arg == "--log-commits") {
            enable_trace = true;
        } else if (arg.substr(0, 6) == "--log=") {
            trace_log_file = arg.substr(6);
        } else if (arg == "--wave" || arg == "--wave=fst" || arg == "--wave=1") {
            enable_wave = true;
            enable_wave_vcd = false;
        } else if (arg == "--wave=vcd") {
            enable_wave = true;
            enable_wave_vcd = true;
        } else if (arg.substr(0, 11) == "+signature=") {
            signature_file = arg.substr(11);
        } else if (arg.substr(0, 23) == "+signature-granularity=") {
            sig_granularity = std::atoi(arg.substr(23).c_str());
            if (sig_granularity != 1 && sig_granularity != 2 && sig_granularity != 4) {
                std::cerr << "Error: signature-granularity must be 1, 2, or 4\n";
                exit(1);
            }
        } else if (arg.substr(0, 2) == "-m") {
            // Parse -m<base>:<size>
            std::string mem_spec = arg.substr(2);
            size_t colon = mem_spec.find(':');
            if (colon == std::string::npos) {
                std::cerr << "Error: invalid memory spec '" << arg << "', expected -m<base>:<size>\n";
                exit(1);
            }
            char* endp;
            uint32_t base = (uint32_t)std::strtoul(mem_spec.substr(0, colon).c_str(), &endp, 0);
            uint32_t size = (uint32_t)std::strtoul(mem_spec.substr(colon + 1).c_str(), &endp, 0);
            if (size == 0) {
                std::cerr << "Error: invalid memory size in '" << arg << "'\n";
                exit(1);
            }
            g_mem_base = base;
            g_mem_size = size;
        } else if (arg.substr(0, 15) == "--instructions=") {
            long long val = std::atoll(arg.substr(15).c_str());
            if (val < 0) {
                std::cerr << "Error: Invalid --instructions value\n";
                exit(1);
            }
            max_instructions = (uint64_t)val;
        } else if (arg[0] != '+' && arg[0] != '-') {
            elf_file = arg;
        } else if (arg[0] != '-' || arg.size() < 2 || arg[1] != '-') {
            // Unknown + or single-dash args: skip (passed to Verilator)
        }
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    parse_args(argc, argv);

    std::signal(SIGINT, handle_sigint);

    if (show_help || elf_file.empty()) {
        print_help(argv[0]);
        return 0;
    }

    Verilated::traceEverOn(true);

    #ifdef HAVE_CHRONO
    std::chrono::steady_clock::time_point time_begin;
    std::chrono::steady_clock::time_point time_end;
    #endif

    // Create instance
    Vtb_kv32_soc* dut = new Vtb_kv32_soc;

    // Create FST/VCD waveform trace (conditional on --wave)
    VerilatedFstC* tfp_fst = nullptr;
#if VM_TRACE_VCD
    VerilatedVcdC* tfp_vcd = nullptr;
#endif
    if (enable_wave) {
        if (enable_wave_vcd) {
#if VM_TRACE_VCD
            tfp_vcd = new VerilatedVcdC;
            dut->trace(tfp_vcd, 99);
            tfp_vcd->open("kv32soc.vcd");
            std::cout << "VCD waveform dump enabled: kv32soc.vcd" << std::endl;
#else
            std::cerr << "WARNING: VCD trace not compiled in (rebuild with --trace instead of --trace-fst). Falling back to FST." << std::endl;
            enable_wave_vcd = false;
            tfp_fst = new VerilatedFstC;
            dut->trace(tfp_fst, 99);
            tfp_fst->open("kv32soc.fst");
            std::cout << "FST waveform dump enabled: kv32soc.fst" << std::endl;
#endif
        } else {
            tfp_fst = new VerilatedFstC;
            dut->trace(tfp_fst, 99);
            tfp_fst->open("kv32soc.fst");
            std::cout << "FST waveform dump enabled: kv32soc.fst" << std::endl;
        }
    }

    // Create trace file (conditional on --trace / --log-commits)
    std::ofstream trace_file;
    RiscvDisassembler* disasm = nullptr;
    if (enable_trace) {
        trace_file.open(trace_log_file);
        if (!trace_file.is_open()) {
            std::cerr << "ERROR: Failed to open " << trace_log_file << " for writing" << std::endl;
            delete dut;
            if (tfp_fst) delete tfp_fst;
#if VM_TRACE_VCD
            if (tfp_vcd) delete tfp_vcd;
#endif
            return 1;
        }
        disasm = new RiscvDisassembler();
        std::cout << "Instruction trace enabled: " << trace_log_file << std::endl;
    }

    // Initialize signals
    dut->clk = 0;
    dut->rst_n = 0;
    dut->uart_rx = 1;
    dut->spi_miso = 1;  // SPI MISO idle high
    dut->i2c_scl_i = 1;  // I2C SCL idle high (external pull-up)
    dut->i2c_sda_i = 1;  // I2C SDA idle high (external pull-up)
    // Trace-compare mode: when +TRACE is active, CSR cycle/time reads in the
    // core return minstret (instruction count) instead of mcycle (wall-clock
    // cycles).  This makes cycle-counter reads pipeline-stall-independent so
    // that the RTL trace and the software-simulator trace are identical.
    dut->trace_mode = enable_trace ? 1 : 0;

    vluint64_t time_counter = 0;
    bool finished = false;
    bool error = false;  // Track if simulation ended with error
    int exit_code = 0;   // Capture exit code from $finish()

    std::cout << "Starting RISC-V SoC simulation..." << std::endl;
    if (max_instructions == 0) {
        std::cout << "Max instructions: unlimited" << std::endl;
    } else {
        std::cout << "Max instructions: " << max_instructions << std::endl;
    }

    // Reset for a few cycles
    for (int i = 0; i < 10; i++) {
        dut->clk = 0;
        dut->eval();
        if (tfp_fst) tfp_fst->dump(time_counter);
#if VM_TRACE_VCD
        if (tfp_vcd) tfp_vcd->dump(time_counter);
#endif
        time_counter++;
        main_time++;

        dut->clk = 1;
        dut->eval();
        if (tfp_fst) tfp_fst->dump(time_counter);
#if VM_TRACE_VCD
        if (tfp_vcd) tfp_vcd->dump(time_counter);
#endif
        time_counter++;
        main_time++;
    }

    // Load program BEFORE releasing reset (so memory is ready when core starts)
    if (!elf_file.empty()) {
        std::cout << "Loading program: " << elf_file << std::endl;
        if (!load_program(dut, elf_file.c_str())) {
            std::cerr << "ERROR: Failed to load program" << std::endl;
            if (tfp_fst) {
                tfp_fst->close();
                delete tfp_fst;
            }
#if VM_TRACE_VCD
            if (tfp_vcd) {
                tfp_vcd->close();
                delete tfp_vcd;
            }
#endif
            if (trace_file.is_open()) trace_file.close();
            if (disasm) delete disasm;
            delete dut;
            return 1;
        }
        std::cout << "Program loaded successfully" << std::endl;
    }

    // Release reset AFTER loading program
    dut->rst_n = 1;
    DEBUG1("Simulation starting with max_instructions=%llu trace=%d", max_instructions, enable_trace);
    std::cout << "==========================================" << std::endl;

    // Run simulation
    int cycle_count = 0;
    uint64_t instr_count = 0;
    bool debug_printed = false;

    // Debug: Check if DPI scope is available
    if (enable_trace) {
        svScope scope = svGetScopeFromName("TOP.tb_kv32_soc");
        if (!scope) {
            scope = svGetScopeFromName("tb_kv32_soc");
        }
        if (scope) {
            std::cout << "DPI scope found and set successfully" << std::endl;
        } else {
            std::cout << "WARNING: DPI scope not found!" << std::endl;
        }
    }

    #ifdef HAVE_CHRONO
    time_begin = std::chrono::steady_clock::now();
    #endif

    while (!exit_requested &&
           (max_instructions == 0 || (uint64_t)dut->instret_count < max_instructions)) {
        if (sigint_received) {
            std::cerr << "\n*** SIGINT received: dumping registers and exiting ***" << std::endl;
            dump_registers();
            error = true;
            break;
        }
        // Clock low
        dut->clk = 0;
        dut->eval();
        if (tfp_fst) tfp_fst->dump(time_counter);
#if VM_TRACE_VCD
        if (tfp_vcd) tfp_vcd->dump(time_counter);
#endif
        time_counter++;
        main_time++;

        // Clock high
        dut->clk = 1;
        dut->eval();
        if (tfp_fst) tfp_fst->dump(time_counter);
#if VM_TRACE_VCD
        if (tfp_vcd) tfp_vcd->dump(time_counter);
#endif
        time_counter++;
        main_time++;

        // Generate trace on clock high (after eval)
        if (enable_trace) {
            dump_instruction_trace(dut, trace_file, disasm, instr_count, cycle_count,
                                  debug_printed);
        }

        // Check for timeout error from RTL (simulation only)
        if (dut->timeout_error) {
            std::cerr << "\n*** STALL TIMEOUT DETECTED ***" << std::endl;
            std::cerr << "Total instructions retired: " << (uint64_t)dut->instret_count << std::endl;
            std::cerr << "Cycle count: " << cycle_count << std::endl;
            error = true;
            break;
        }

        cycle_count++;
    }

    finished = true;

    // Capture exit code if exit was requested via DPI
    if (exit_requested) {
        exit_code = exit_code_value;
    }

    #ifdef HAVE_CHRONO
    time_end = std::chrono::steady_clock::now();
    #endif

    // Print CPU Statistics
    std::cout << std::endl;
    std::cout << "==========================================" << std::endl;
    std::cout << "Simulator statistics" << std::endl;
    std::cout << "==========================================" << std::endl;
    std::cout << "CPU Operations:" << std::endl;

    #ifdef HAVE_CHRONO
    {
        float sec = std::chrono::duration_cast<std::chrono::milliseconds>(time_end - time_begin).count() / 1000.0;
        if (sec == 0) {
            std::cout << "  Simulation speed :           N/A" << std::endl;
        } else {
            float speed_mhz = cycle_count / sec / 1000000.0;
            std::cout << "  Simulation speed :           " << speed_mhz << "MHz" << std::endl;
        }
    }
    #endif

    std::cout << "  Simulation time :            " << main_time << " ns" << std::endl;
    std::cout << "  Total cycles :               " << cycle_count << std::endl;
    std::cout << "  Instructions :               " << (uint64_t)dut->instret_count << std::endl;

    if (dut->instret_count > 0) {
        // CPI = (last retire cycle - first retire cycle) / instructions
        uint64_t execution_cycles = dut->last_retire_cycle - dut->first_retire_cycle;
        uint64_t stall_cycles = execution_cycles - dut->instret_count;
        double stall_percentage = (double)stall_cycles / (double)execution_cycles * 100.0;
        double cpi = (double)execution_cycles / (double)dut->instret_count;
        std::cout << "  Execution cycles :           " << execution_cycles << std::endl;
        std::cout << "  Stall cycles :               " << stall_cycles << " (" << std::fixed << std::setprecision(2) << stall_percentage << "%)" << std::endl;
        std::cout << "  CPI :                        " << cpi << std::endl;
    }

    // Print AXI Memory Statistics
    // Set DPI scope to ext_mem instance where statistics functions are exported
    svScope mem_scope = svGetScopeFromName("TOP.tb_kv32_soc.ext_mem");
    if (!mem_scope) {
        mem_scope = svGetScopeFromName("tb_kv32_soc.ext_mem");
    }
    if (mem_scope) {
        svSetScope(mem_scope);
    } else {
        std::cerr << "WARNING: Could not find ext_mem scope for statistics" << std::endl;
    }

    int ar_requests = mem_get_stat_ar_requests();
    int r_responses = mem_get_stat_r_responses();
    int aw_requests = mem_get_stat_aw_requests();
    int w_data       = mem_get_stat_w_data();
    int w_expected   = mem_get_stat_w_expected();
    int b_responses  = mem_get_stat_b_responses();
    int max_outstanding_reads = mem_get_stat_max_outstanding_reads();
    int max_outstanding_writes = mem_get_stat_max_outstanding_writes();

    std::cout << std::endl;
    std::cout << "Read Operations :" << std::endl;
    std::cout << "  AR Requests (Master) :       " << ar_requests << std::endl;
    std::cout << "  R Responses (Slave) :        " << r_responses << std::endl;
    if ((ar_requests - r_responses) > 1) {
        // Diff of 1 is always expected: at normal program exit the CPU has one
        // instruction fetch in-flight (AR accepted, R not yet returned). Only
        // warn when the outstanding count is unexpectedly large.
        std::cout << "  WARNING: Mismatch AR=" << ar_requests << ", R=" << r_responses
                  << " (Diff=" << (ar_requests - r_responses) << ")" << std::endl;
    }
    std::cout << "  Max Outstanding Reads :      " << max_outstanding_reads << std::endl;
    std::cout << std::endl;

    std::cout << "Write Operations :" << std::endl;
    std::cout << "  AW Requests (Master) :       " << aw_requests << std::endl;
    std::cout << "  W Data Beats (actual) :      " << w_data << std::endl;
    std::cout << "  W Data Beats (expected) :    " << w_expected << std::endl;
    std::cout << "  B Responses (Slave) :        " << b_responses << std::endl;
    if (aw_requests != b_responses) {
        std::cout << "  WARNING: Mismatch AW=" << aw_requests << ", B=" << b_responses
                  << " (Diff=" << (aw_requests - b_responses) << ")" << std::endl;
    }
    // w_expected = sum of (awlen+1) per AW transaction; w_data = actual W beats observed.
    // They must match: any difference means beats were lost or spuriously generated.
    if (w_data != w_expected) {
        std::cout << "  WARNING: Mismatch W_expected=" << w_expected << ", W_actual=" << w_data
                  << " (Diff=" << (w_expected - w_data) << ") -- burst beat count inconsistency!" << std::endl;
    }
    std::cout << "  Max Outstanding Writes :     " << max_outstanding_writes << std::endl;
    std::cout << std::endl;

    std::cout << "Total Transactions :           " << (ar_requests + aw_requests) << std::endl;

#if ICACHE_EN
    // Print I-Cache performance statistics
    {
        uint64_t req    = (uint64_t)dut->icache_perf_req_cnt;
        uint64_t hits   = (uint64_t)dut->icache_perf_hit_cnt;
        uint64_t misses = (uint64_t)dut->icache_perf_miss_cnt;
        uint64_t bypass = (uint64_t)dut->icache_perf_bypass_cnt;
        uint64_t fills  = (uint64_t)dut->icache_perf_fill_cnt;
        uint64_t cmos   = (uint64_t)dut->icache_perf_cmo_cnt;
        double   hit_rate = req ? (100.0 * hits / req) : 0.0;

        std::cout << std::endl;
        std::cout << "I-Cache Statistics :" << std::endl;
        std::cout << "  Cache size :                 " << ICACHE_SIZE << " B  "
                  << "(" << (ICACHE_SIZE / 1024) << " KB, "
                  << ICACHE_WAYS << "-way, "
                  << ICACHE_LINE_SIZE << "-byte lines)" << std::endl;
        std::cout << "  Fetch lookups :              " << req    << std::endl;
        std::cout << "  Cache hits :                 " << hits
                  << " (" << std::fixed << std::setprecision(2) << hit_rate << "%)" << std::endl;
        std::cout << "  Cache misses :               " << misses << std::endl;
        std::cout << "  Bypass fetches :             " << bypass << std::endl;
        std::cout << "  Cache-line fills :           " << fills  << std::endl;
        std::cout << "  CMO operations :             " << cmos   << std::endl;
    }
#endif

    std::cout << "==========================================" << std::endl;

    // Write RISCOF signature file if requested
    if (!signature_file.empty()) {
        auto it_begin = g_symbols.find("begin_signature");
        auto it_end   = g_symbols.find("end_signature");
        if (it_begin == g_symbols.end() || it_end == g_symbols.end()) {
            std::cerr << "WARNING: begin_signature/end_signature symbols not found; "
                      << "signature file not written" << std::endl;
        } else {
            // Re-use the ext_mem DPI scope to read back memory bytes
            svScope sig_scope = svGetScopeFromName("TOP.tb_kv32_soc.ext_mem");
            if (!sig_scope) sig_scope = svGetScopeFromName("tb_kv32_soc.ext_mem");
            if (sig_scope) svSetScope(sig_scope);

            uint32_t begin_addr = it_begin->second.addr;
            uint32_t end_addr   = it_end->second.addr;

            std::ofstream sig_out(signature_file);
            if (!sig_out.is_open()) {
                std::cerr << "ERROR: Cannot open signature file: " << signature_file << std::endl;
            } else {
                for (uint32_t addr = begin_addr; addr < end_addr; addr += sig_granularity) {
                    uint32_t val = 0;
                    for (int b = sig_granularity - 1; b >= 0; b--) {
                        uint32_t offset = addr + b - g_mem_base;
                        uint8_t byte_val = (uint8_t)mem_read_byte((int)offset);
                        val = (val << 8) | byte_val;
                    }
                    sig_out << std::hex << std::setw(sig_granularity * 2)
                            << std::setfill('0') << val << "\n";
                }
                std::cout << "Signature written to: " << signature_file << std::endl;
            }
        }
    }
    if (!exit_requested && max_instructions > 0 && (uint64_t)dut->instret_count >= max_instructions) {
        std::cerr << "\n*** ERROR: Simulation reached maximum instruction limit (" << max_instructions << ") ***" << std::endl;
        std::cerr << "*** Program did not complete normally (no exit request) ***" << std::endl;
        std::cerr << "*** Consider increasing --instructions or check for infinite loops ***" << std::endl;
        error = true;
    }

    // Cleanup
    if (tfp_fst) {
        tfp_fst->close();
        delete tfp_fst;
    }
#if VM_TRACE_VCD
    if (tfp_vcd) {
        tfp_vcd->close();
        delete tfp_vcd;
    }
#endif
    if (trace_file.is_open()) {
        trace_file.close();
    }
    if (disasm) {
        delete disasm;
    }

    // Write coverage data if enabled
#if VM_COVERAGE
    VerilatedCov::write("objdir/coverage.dat");
#endif

    delete dut;

    // Return 0 for success, 1 for error
    if (error) {
        return 1;  // Abnormal termination (infinite loop, timeout, etc.)
    } else if (exit_requested) {
        return exit_code;  // Normal termination - return the actual exit code
    } else {
        return 1;  // Unexpected termination
    }

    return 0;
}
