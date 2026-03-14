/**
 * @file csr.h
 * @brief RISC-V CSR (Control and Status Register) inline accessor macros.
 *
 * Provides read_csr(), write_csr(), set_csr(), clear_csr() wrappers
 * and named constants for every machine-mode CSR used by kv32_core.
 * @ingroup platform
 */

#ifndef CSR_H
#define CSR_H

#include <stdint.h>

#define UNUSED(x) (void)(x)

// ============================================================================
// Machine Information Registers (Read-Only)
// ============================================================================

static inline uint32_t read_csr_mvendorid(void) {
    uint32_t val;
    asm volatile("csrr %0, mvendorid" : "=r"(val));
    return val;
}

static inline uint32_t read_csr_marchid(void) {
    uint32_t val;
    asm volatile("csrr %0, marchid" : "=r"(val));
    return val;
}

static inline uint32_t read_csr_mimpid(void) {
    uint32_t val;
    asm volatile("csrr %0, mimpid" : "=r"(val));
    return val;
}

static inline uint32_t read_csr_mhartid(void) {
    uint32_t val;
    asm volatile("csrr %0, mhartid" : "=r"(val));
    return val;
}

// ============================================================================
// Machine Trap Setup
// ============================================================================

// mstatus - Machine Status Register
static inline uint32_t read_csr_mstatus(void) {
    uint32_t val;
    asm volatile("csrr %0, mstatus" : "=r"(val));
    return val;
}

static inline void write_csr_mstatus(uint32_t val) {
    asm volatile("csrw mstatus, %0" :: "r"(val));
}

// misa - ISA and Extensions
static inline uint32_t read_csr_misa(void) {
    uint32_t val;
    asm volatile("csrr %0, misa" : "=r"(val));
    return val;
}

// mie - Machine Interrupt Enable
static inline uint32_t read_csr_mie(void) {
    uint32_t val;
    asm volatile("csrr %0, mie" : "=r"(val));
    return val;
}

static inline void write_csr_mie(uint32_t val) {
    asm volatile("csrw mie, %0" :: "r"(val));
}

// mtvec - Machine Trap-Vector Base Address
static inline uint32_t read_csr_mtvec(void) {
    uint32_t val;
    asm volatile("csrr %0, mtvec" : "=r"(val));
    return val;
}

static inline void write_csr_mtvec(uint32_t val) {
    asm volatile("csrw mtvec, %0" :: "r"(val));
}

// ============================================================================
// Machine Trap Handling
// ============================================================================

// mscratch - Machine Scratch Register
static inline uint32_t read_csr_mscratch(void) {
    uint32_t val;
    asm volatile("csrr %0, mscratch" : "=r"(val));
    return val;
}

static inline void write_csr_mscratch(uint32_t val) {
    asm volatile("csrw mscratch, %0" :: "r"(val));
}

// mepc - Machine Exception Program Counter
static inline uint32_t read_csr_mepc(void) {
    uint32_t val;
    asm volatile("csrr %0, mepc" : "=r"(val));
    return val;
}

static inline void write_csr_mepc(uint32_t val) {
    asm volatile("csrw mepc, %0" :: "r"(val));
}

// mcause - Machine Cause Register
static inline uint32_t read_csr_mcause(void) {
    uint32_t val;
    asm volatile("csrr %0, mcause" : "=r"(val));
    return val;
}

static inline void write_csr_mcause(uint32_t val) {
    asm volatile("csrw mcause, %0" :: "r"(val));
}

// mtval - Machine Trap Value
static inline uint32_t read_csr_mtval(void) {
    uint32_t val;
    asm volatile("csrr %0, mtval" : "=r"(val));
    return val;
}

static inline void write_csr_mtval(uint32_t val) {
    asm volatile("csrw mtval, %0" :: "r"(val));
}

// mip - Machine Interrupt Pending
static inline uint32_t read_csr_mip(void) {
    uint32_t val;
    asm volatile("csrr %0, mip" : "=r"(val));
    return val;
}

static inline void write_csr_mip(uint32_t val) {
    asm volatile("csrw mip, %0" :: "r"(val));
}

// ============================================================================
// Custom Machine CSRs (KV32)
// ============================================================================

static inline uint32_t read_csr_sguard_base(void) {
    uint32_t val;
    asm volatile("csrr %0, 0x7cc" : "=r"(val));
    return val;
}

static inline void write_csr_sguard_base(uint32_t val) {
    asm volatile("csrw 0x7cc, %0" :: "r"(val));
}

static inline uint32_t read_csr_spmin(void) {
    uint32_t val;
    asm volatile("csrr %0, 0x7cd" : "=r"(val));
    return val;
}

static inline void write_csr_spmin(uint32_t val) {
    asm volatile("csrw 0x7cd, %0" :: "r"(val));
}

// ============================================================================
// Machine Counter/Timers
// ============================================================================

// mcycle - Machine Cycle Counter (lower 32 bits)
static inline uint32_t read_csr_mcycle(void) {
    uint32_t val;
    asm volatile("csrr %0, mcycle" : "=r"(val));
    return val;
}

static inline void write_csr_mcycle(uint32_t val) {
    asm volatile("csrw mcycle, %0" :: "r"(val));
}

// mcycleh - Machine Cycle Counter (upper 32 bits)
static inline uint32_t read_csr_mcycleh(void) {
    uint32_t val;
    asm volatile("csrr %0, mcycleh" : "=r"(val));
    return val;
}

static inline void write_csr_mcycleh(uint32_t val) {
    asm volatile("csrw mcycleh, %0" :: "r"(val));
}

// minstret - Machine Instructions Retired (lower 32 bits)
static inline uint32_t read_csr_minstret(void) {
    uint32_t val;
    asm volatile("csrr %0, minstret" : "=r"(val));
    return val;
}

static inline void write_csr_minstret(uint32_t val) {
    asm volatile("csrw minstret, %0" :: "r"(val));
}

// minstreth - Machine Instructions Retired (upper 32 bits)
static inline uint32_t read_csr_minstreth(void) {
    uint32_t val;
    asm volatile("csrr %0, minstreth" : "=r"(val));
    return val;
}

static inline void write_csr_minstreth(uint32_t val) {
    asm volatile("csrw minstreth, %0" :: "r"(val));
}

// ============================================================================
// User-mode Counter/Timers (Read-Only aliases)
// ============================================================================

// cycle - Cycle counter (user read-only)
static inline uint32_t read_csr_cycle(void) {
    uint32_t val;
    asm volatile("csrr %0, cycle" : "=r"(val));
    return val;
}

// cycleh - Cycle counter high (user read-only)
static inline uint32_t read_csr_cycleh(void) {
    uint32_t val;
    asm volatile("csrr %0, cycleh" : "=r"(val));
    return val;
}

// time - Timer (user read-only)
static inline uint32_t read_csr_time(void) {
    uint32_t val;
    asm volatile("csrr %0, time" : "=r"(val));
    return val;
}

// timeh - Timer high (user read-only)
static inline uint32_t read_csr_timeh(void) {
    uint32_t val;
    asm volatile("csrr %0, timeh" : "=r"(val));
    return val;
}

// instret - Instructions retired (user read-only)
static inline uint32_t read_csr_instret(void) {
    uint32_t val;
    asm volatile("csrr %0, instret" : "=r"(val));
    return val;
}

// instreth - Instructions retired high (user read-only)
static inline uint32_t read_csr_instreth(void) {
    uint32_t val;
    asm volatile("csrr %0, instreth" : "=r"(val));
    return val;
}

// ============================================================================
// Helper Functions - Read 64-bit counters
// ============================================================================

// Read 64-bit cycle counter (handles wraparound)
static inline uint64_t read_csr_cycle64(void) {
    uint32_t lo, hi, hi2;
    do {
        hi = read_csr_cycleh();
        lo = read_csr_cycle();
        hi2 = read_csr_cycleh();
    } while (hi != hi2);  // Retry if high word changed
    return ((uint64_t)hi << 32) | lo;
}

// Read 64-bit instruction counter (handles wraparound)
static inline uint64_t read_csr_instret64(void) {
    uint32_t lo, hi, hi2;
    do {
        hi = read_csr_instreth();
        lo = read_csr_instret();
        hi2 = read_csr_instreth();
    } while (hi != hi2);  // Retry if high word changed
    return ((uint64_t)hi << 32) | lo;
}

// Read 64-bit time counter (handles wraparound)
static inline uint64_t read_csr_time64(void) {
    uint32_t lo, hi, hi2;
    do {
        hi = read_csr_timeh();
        lo = read_csr_time();
        hi2 = read_csr_timeh();
    } while (hi != hi2);  // Retry if high word changed
    return ((uint64_t)hi << 32) | lo;
}

// ============================================================================
// CSR Bit Manipulation Operations
// ============================================================================

// Set bits in CSR (read-modify-write)
static inline void csr_set_mstatus(uint32_t mask) {
    asm volatile("csrs mstatus, %0" :: "r"(mask));
}

static inline void csr_set_mie(uint32_t mask) {
    asm volatile("csrs mie, %0" :: "r"(mask));
}

// Clear bits in CSR (read-modify-write)
static inline void csr_clear_mstatus(uint32_t mask) {
    asm volatile("csrc mstatus, %0" :: "r"(mask));
}

static inline void csr_clear_mie(uint32_t mask) {
    asm volatile("csrc mie, %0" :: "r"(mask));
}

// ============================================================================
// CSR Bit Definitions
// ============================================================================

// mstatus bits
#define MSTATUS_MIE   (1 << 3)   // Machine Interrupt Enable
#define MSTATUS_MPIE  (1 << 7)   // Previous MIE
#define MSTATUS_MPP_SHIFT 11     // Previous Privilege Mode
#define MSTATUS_MPP_MASK  (3 << MSTATUS_MPP_SHIFT)

// mie/mip bits
#define MIE_MSIE  (1 << 3)   // Machine Software Interrupt Enable
#define MIE_MTIE  (1 << 7)   // Machine Timer Interrupt Enable
#define MIE_MEIE  (1 << 11)  // Machine External Interrupt Enable

#define MIP_MSIP  (1 << 3)   // Machine Software Interrupt Pending
#define MIP_MTIP  (1 << 7)   // Machine Timer Interrupt Pending
#define MIP_MEIP  (1 << 11)  // Machine External Interrupt Pending

// mcause interrupt bit and exception codes
#define MCAUSE_INTERRUPT  (1U << 31)  // Interrupt flag
#define MCAUSE_CODE_MASK  0x7FFFFFFF  // Exception/interrupt code

// Exception codes (mcause with MCAUSE_INTERRUPT=0)
#define EXCEPTION_INSTR_ADDR_MISALIGNED  0
#define EXCEPTION_INSTR_ACCESS_FAULT     1
#define EXCEPTION_ILLEGAL_INSTR          2
#define EXCEPTION_BREAKPOINT             3
#define EXCEPTION_LOAD_ADDR_MISALIGNED   4
#define EXCEPTION_LOAD_ACCESS_FAULT      5
#define EXCEPTION_STORE_ADDR_MISALIGNED  6
#define EXCEPTION_STORE_ACCESS_FAULT     7
#define EXCEPTION_ECALL_FROM_UMODE       8
#define EXCEPTION_ECALL_FROM_MMODE       11
#define EXCEPTION_STACK_OVERFLOW         16

// Interrupt codes (mcause with MCAUSE_INTERRUPT=1)
#define INTERRUPT_SOFTWARE  3   // Machine software interrupt
#define INTERRUPT_TIMER     7   // Machine timer interrupt
#define INTERRUPT_EXTERNAL  11  // Machine external interrupt

#endif // CSR_H
