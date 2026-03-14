/**
 * @file kv_irq.h
 * @brief Machine-mode interrupt and exception management API.
 *
 * Covers global MIE enable/disable, per-source mie bit control,
 * per-cause IRQ/exception handler registration, and trap entry hooks.
 * @ingroup drivers
 */

#ifndef KV_IRQ_H
#define KV_IRQ_H

#include <stdint.h>
#include "csr.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ═══════════════════════════════════════════════════════════════════
 * mie / mip bit positions
 * ══════════════════════════════════════════════════════════════════ */
#define KV_IRQ_MSIE     (1u <<  3)   /* Machine software interrupt enable */
#define KV_IRQ_MTIE     (1u <<  7)   /* Machine timer    interrupt enable */
#define KV_IRQ_MEIE     (1u << 11)   /* Machine external interrupt enable */

/* mcause interrupt codes (MSB stripped) */
#define KV_CAUSE_MSI    3u           /* Machine software interrupt        */
#define KV_CAUSE_MTI    7u           /* Machine timer    interrupt        */
#define KV_CAUSE_MEI    11u          /* Machine external interrupt        */

/* Exception cause codes */
#define KV_EXC_INSN_MISALIGN    0u
#define KV_EXC_INSN_FAULT       1u
#define KV_EXC_ILLEGAL_INSN     2u
#define KV_EXC_BREAKPOINT       3u
#define KV_EXC_LOAD_MISALIGN    4u
#define KV_EXC_LOAD_FAULT       5u
#define KV_EXC_STORE_MISALIGN   6u
#define KV_EXC_STORE_FAULT      7u
#define KV_EXC_ECALL_U          8u
#define KV_EXC_ECALL_M          11u

/* ═══════════════════════════════════════════════════════════════════
 * Trap frame — mirrors the register save layout in start.S
 *
 * start.S allocates 144 bytes on entry (addi sp, sp, -144):
 *
 *   offset   field      register / CSR
 *   ------   --------   ---------------
 *    +0      _pad       (x0 placeholder, always 0)
 *    +4      ra         x1
 *    +8      sp         x2  (stack pointer at trap entry, post-alloc)
 *    +12     gp         x3
 *    +16     tp         x4
 *    +20     t0         x5
 *    +24     t1         x6
 *    +28     t2         x7
 *    +32     s0         x8 / fp
 *    +36     s1         x9
 *    +40     a0         x10
 *    +44     a1         x11
 *    +48     a2         x12
 *    +52     a3         x13
 *    +56     a4         x14
 *    +60     a5         x15
 *    +64     a6         x16
 *    +68     a7         x17
 *    +72     s2         x18
 *    +76     s3         x19
 *    +80     s4         x20
 *    +84     s5         x21
 *    +88     s6         x22
 *    +92     s7         x23
 *    +96     s8         x24
 *    +100    s9         x25
 *    +104    s10        x26
 *    +108    s11        x27
 *    +112    t3         x28
 *    +116    t4         x29
 *    +120    t5         x30
 *    +124    t6         x31
 *    +128    mepc       mepc CSR  (handler may update to redirect return PC)
 *    +132    mstatus    mstatus CSR
 *    +136    mcause     mcause CSR (read-only for handlers)
 *    +140    mtval      mtval CSR  (read-only for handlers)
 *
 * Exception handlers receive a pointer to this struct and may update
 * frame->mepc to redirect the return PC (e.g. skip a faulting instruction).
 * The epilogue restores mepc from frame->mepc before mret, so the update
 * takes effect without any direct CSR write inside the handler.
 * ══════════════════════════════════════════════════════════════════ */
typedef struct kv_trap_frame {
    uint32_t _pad;      /* +0   x0 placeholder */
    uint32_t ra;        /* +4   x1  */
    uint32_t sp;        /* +8   x2  (stack pointer at trap entry) */
    uint32_t gp;        /* +12  x3  */
    uint32_t tp;        /* +16  x4  */
    uint32_t t0;        /* +20  x5  */
    uint32_t t1;        /* +24  x6  */
    uint32_t t2;        /* +28  x7  */
    uint32_t s0;        /* +32  x8/fp */
    uint32_t s1;        /* +36  x9  */
    uint32_t a0;        /* +40  x10 */
    uint32_t a1;        /* +44  x11 */
    uint32_t a2;        /* +48  x12 */
    uint32_t a3;        /* +52  x13 */
    uint32_t a4;        /* +56  x14 */
    uint32_t a5;        /* +60  x15 */
    uint32_t a6;        /* +64  x16 */
    uint32_t a7;        /* +68  x17 */
    uint32_t s2;        /* +72  x18 */
    uint32_t s3;        /* +76  x19 */
    uint32_t s4;        /* +80  x20 */
    uint32_t s5;        /* +84  x21 */
    uint32_t s6;        /* +88  x22 */
    uint32_t s7;        /* +92  x23 */
    uint32_t s8;        /* +96  x24 */
    uint32_t s9;        /* +100 x25 */
    uint32_t s10;       /* +104 x26 */
    uint32_t s11;       /* +108 x27 */
    uint32_t t3;        /* +112 x28 */
    uint32_t t4;        /* +116 x29 */
    uint32_t t5;        /* +120 x30 */
    uint32_t t6;        /* +124 x31 */
    uint32_t mepc;      /* +128 return PC (writable by exception handlers) */
    uint32_t mstatus;   /* +132 */
    uint32_t mcause;    /* +136 (read-only for handlers) */
    uint32_t mtval;     /* +140 (read-only for handlers) */
} kv_trap_frame_t;

/* ═══════════════════════════════════════════════════════════════════
 * Handler typedefs
 * ══════════════════════════════════════════════════════════════════ */

/* IRQ handler: called with interrupt cause code (MSB stripped from mcause) */
typedef void (*kv_irq_handler_t)(uint32_t cause);

/* Exception handler: receives the full saved register frame.
 * Set frame->mepc to redirect the return PC (e.g. skip a faulting
 * instruction) instead of calling write_csr_mepc() directly. */
typedef void (*kv_exc_handler_t)(kv_trap_frame_t *frame);

/* ═══════════════════════════════════════════════════════════════════
 * Global interrupt enable / disable
 * ══════════════════════════════════════════════════════════════════ */

/* Enable machine-mode interrupts globally (set mstatus.MIE). */
static inline void kv_irq_enable(void)
{
    asm volatile("csrsi mstatus, 0x8");
}

/* Disable machine-mode interrupts globally (clear mstatus.MIE).
 * Returns the previous mstatus so callers can restore it. */
static inline uint32_t kv_irq_disable(void)
{
    uint32_t prev = read_csr_mstatus();
    asm volatile("csrci mstatus, 0x8");
    return prev;
}

/* Restore mstatus from a value previously returned by kv_irq_disable(). */
static inline void kv_irq_restore(uint32_t saved_mstatus)
{
    write_csr_mstatus(saved_mstatus);
}

/* ═══════════════════════════════════════════════════════════════════
 * Per-source interrupt enable / disable  (mie CSR)
 * ══════════════════════════════════════════════════════════════════ */

/* Enable one or more interrupt sources (KV_IRQ_MSIE / _MTIE / _MEIE). */
static inline void kv_irq_source_enable(uint32_t mask)
{
    write_csr_mie(read_csr_mie() | mask);
}

/* Disable one or more interrupt sources. */
static inline void kv_irq_source_disable(uint32_t mask)
{
    write_csr_mie(read_csr_mie() & ~mask);
}

/* Return whether a source (or combination) is currently enabled. */
static inline int kv_irq_source_is_enabled(uint32_t mask)
{
    return (read_csr_mie() & mask) == mask;
}

/* ═══════════════════════════════════════════════════════════════════
 * Wait For Interrupt (WFI)
 * ══════════════════════════════════════════════════════════════════ */

/* Suspend execution until an interrupt becomes pending.
 *
 * The processor stalls in the WFI instruction until any enabled interrupt
 * fires.  Upon wake-up the interrupt handler is entered and execution
 * resumes at WFI+4 after the handler returns (MRET).
 *
 * Typical usage: call kv_irq_enable() first, then spin calling kv_wfi()
 * inside an idle loop so that the core clocks are gated between events.
 *
 *   kv_irq_enable();
 *   while (!done)
 *       kv_wfi();
 */
static inline void kv_wfi(void)
{
    asm volatile("wfi");
}

/* ═══════════════════════════════════════════════════════════════════
 * Handler registration
 * ══════════════════════════════════════════════════════════════════ */

/* Register a software/timer/external interrupt handler.
 * cause must be KV_CAUSE_MSI, KV_CAUSE_MTI or KV_CAUSE_MEI.
 * Pass NULL to restore the default (print-and-continue) behaviour. */
void kv_irq_register(uint32_t cause, kv_irq_handler_t handler);

/* Register an exception handler for a given exception cause code
 * (KV_EXC_*).  Pass NULL to restore the default (print-and-hang). */
void kv_exc_register(uint32_t cause, kv_exc_handler_t handler);

/* ═══════════════════════════════════════════════════════════════════
 * Top-level trap handler – called from trap_vector in start.S.
 * Weak symbol; individual tests may override it.
 * ══════════════════════════════════════════════════════════════════ */
void trap_handler(kv_trap_frame_t *frame);

/* ═══════════════════════════════════════════════════════════════════
 * Dispatcher – called by trap_handler  (do not call directly)
 * ══════════════════════════════════════════════════════════════════ */
void kv_irq_dispatch(kv_trap_frame_t *frame);

#ifdef __cplusplus
}
#endif

#endif /* KV_IRQ_H */
