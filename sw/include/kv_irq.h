// ============================================================================
// File: kv_irq.h
// Project: KV32 RISC-V Processor
// Description: Machine-mode interrupt and exception management API
//
// Covers: global MIE enable/disable, per-source mie bit control,
// per-cause IRQ/exception handler registration, and trap entry hooks.
// ============================================================================

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
 * Handler typedefs
 * ══════════════════════════════════════════════════════════════════ */

/* IRQ handler: called with interrupt cause code (MSB stripped from mcause) */
typedef void (*kv_irq_handler_t)(uint32_t cause);

/* Exception handler: called with full mcause, mepc, mtval */
typedef void (*kv_exc_handler_t)(uint32_t mcause, uint32_t mepc, uint32_t mtval);

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
 * Dispatcher – called by trap_vector in start.S  (do not call directly)
 * ══════════════════════════════════════════════════════════════════ */
void kv_irq_dispatch(uint32_t mcause, uint32_t mepc, uint32_t mtval);

#ifdef __cplusplus
}
#endif

#endif /* KV_IRQ_H */
