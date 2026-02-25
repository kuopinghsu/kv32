/*
 * rv_irq.h – Machine-mode interrupt and trap management API
 *
 * Covers:
 *   - Global interrupt enable/disable (mstatus.MIE)
 *   - Individual interrupt enable/disable (mie CSR)
 *   - Per-cause IRQ handler registration
 *   - Exception (trap) handler hook
 *   - Low-level I/O for the default trap_handler
 */
#ifndef RV_IRQ_H
#define RV_IRQ_H

#include <stdint.h>
#include "csr.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ═══════════════════════════════════════════════════════════════════
 * mie / mip bit positions
 * ══════════════════════════════════════════════════════════════════ */
#define RV_IRQ_MSIE     (1u <<  3)   /* Machine software interrupt enable */
#define RV_IRQ_MTIE     (1u <<  7)   /* Machine timer    interrupt enable */
#define RV_IRQ_MEIE     (1u << 11)   /* Machine external interrupt enable */

/* mcause interrupt codes (MSB stripped) */
#define RV_CAUSE_MSI    3u           /* Machine software interrupt        */
#define RV_CAUSE_MTI    7u           /* Machine timer    interrupt        */
#define RV_CAUSE_MEI    11u          /* Machine external interrupt        */

/* Exception cause codes */
#define RV_EXC_INSN_MISALIGN    0u
#define RV_EXC_INSN_FAULT       1u
#define RV_EXC_ILLEGAL_INSN     2u
#define RV_EXC_BREAKPOINT       3u
#define RV_EXC_LOAD_MISALIGN    4u
#define RV_EXC_LOAD_FAULT       5u
#define RV_EXC_STORE_MISALIGN   6u
#define RV_EXC_STORE_FAULT      7u
#define RV_EXC_ECALL_U          8u
#define RV_EXC_ECALL_M          11u

/* ═══════════════════════════════════════════════════════════════════
 * Handler typedefs
 * ══════════════════════════════════════════════════════════════════ */

/* IRQ handler: called with interrupt cause code (MSB stripped from mcause) */
typedef void (*rv_irq_handler_t)(uint32_t cause);

/* Exception handler: called with full mcause, mepc, mtval */
typedef void (*rv_exc_handler_t)(uint32_t mcause, uint32_t mepc, uint32_t mtval);

/* ═══════════════════════════════════════════════════════════════════
 * Global interrupt enable / disable
 * ══════════════════════════════════════════════════════════════════ */

/* Enable machine-mode interrupts globally (set mstatus.MIE). */
static inline void rv_irq_enable(void)
{
    asm volatile("csrsi mstatus, 0x8");
}

/* Disable machine-mode interrupts globally (clear mstatus.MIE).
 * Returns the previous mstatus so callers can restore it. */
static inline uint32_t rv_irq_disable(void)
{
    uint32_t prev = read_csr_mstatus();
    asm volatile("csrci mstatus, 0x8");
    return prev;
}

/* Restore mstatus from a value previously returned by rv_irq_disable(). */
static inline void rv_irq_restore(uint32_t saved_mstatus)
{
    write_csr_mstatus(saved_mstatus);
}

/* ═══════════════════════════════════════════════════════════════════
 * Per-source interrupt enable / disable  (mie CSR)
 * ══════════════════════════════════════════════════════════════════ */

/* Enable one or more interrupt sources (RV_IRQ_MSIE / _MTIE / _MEIE). */
static inline void rv_irq_source_enable(uint32_t mask)
{
    write_csr_mie(read_csr_mie() | mask);
}

/* Disable one or more interrupt sources. */
static inline void rv_irq_source_disable(uint32_t mask)
{
    write_csr_mie(read_csr_mie() & ~mask);
}

/* Return whether a source (or combination) is currently enabled. */
static inline int rv_irq_source_is_enabled(uint32_t mask)
{
    return (read_csr_mie() & mask) == mask;
}

/* ═══════════════════════════════════════════════════════════════════
 * Handler registration
 * ══════════════════════════════════════════════════════════════════ */

/* Register a software/timer/external interrupt handler.
 * cause must be RV_CAUSE_MSI, RV_CAUSE_MTI or RV_CAUSE_MEI.
 * Pass NULL to restore the default (print-and-continue) behaviour. */
void rv_irq_register(uint32_t cause, rv_irq_handler_t handler);

/* Register an exception handler for a given exception cause code
 * (RV_EXC_*).  Pass NULL to restore the default (print-and-hang). */
void rv_exc_register(uint32_t cause, rv_exc_handler_t handler);

/* ═══════════════════════════════════════════════════════════════════
 * Dispatcher – called by trap_vector in start.S  (do not call directly)
 * ══════════════════════════════════════════════════════════════════ */
void rv_irq_dispatch(uint32_t mcause, uint32_t mepc, uint32_t mtval);

#ifdef __cplusplus
}
#endif

#endif /* RV_IRQ_H */
