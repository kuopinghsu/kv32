/*
 * rv_plic.h – Platform-Level Interrupt Controller (PLIC) driver
 *
 * Supports a single hart (hart 0, machine-mode context 0).
 * IRQ source IDs are defined in rv_platform.h (RV_PLIC_SRC_*).
 */
#ifndef RV_PLIC_H
#define RV_PLIC_H

#include <stdint.h>
#include "rv_platform.h"
#include "rv_irq.h"

/* Maximum number of interrupt sources supported by this driver */
#define RV_PLIC_MAX_SOURCES  32u

/* ─── register accessors ──────────────────────────────────────────── */

/* Source priority register for source n (1-based) */
#define RV_PLIC_PRIORITY(n) \
    RV_REG32(RV_PLIC_BASE, RV_PLIC_PRIORITY_OFF + (uint32_t)(n) * 4u)

/* Pending bit array (32 sources in word 0) */
#define RV_PLIC_PENDING     RV_REG32(RV_PLIC_BASE, RV_PLIC_PENDING_OFF)

/* Enable bits for context 0 */
#define RV_PLIC_ENABLE      RV_REG32(RV_PLIC_BASE, RV_PLIC_ENABLE_OFF)

/* Priority threshold for context 0 */
#define RV_PLIC_THRESHOLD   RV_REG32(RV_PLIC_BASE, RV_PLIC_THRESHOLD_OFF)

/* Claim / complete register for context 0 */
#define RV_PLIC_CLAIM       RV_REG32(RV_PLIC_BASE, RV_PLIC_CLAIM_OFF)

/* ─── source-level control ────────────────────────────────────────── */

/* Set the priority for a PLIC source (1..7; 0 = effectively disabled). */
static inline void rv_plic_set_priority(uint32_t src, uint32_t priority)
{
    RV_PLIC_PRIORITY(src) = priority;
}

/* Enable a PLIC source for context 0. */
static inline void rv_plic_enable_source(uint32_t src)
{
    RV_PLIC_ENABLE |= (1u << src);
}

/* Disable a PLIC source for context 0. */
static inline void rv_plic_disable_source(uint32_t src)
{
    RV_PLIC_ENABLE &= ~(1u << src);
}

/* Check whether a source has a pending interrupt. */
static inline int rv_plic_is_pending(uint32_t src)
{
    return (RV_PLIC_PENDING >> src) & 1u;
}

/* ─── threshold ───────────────────────────────────────────────────── */

/* Set the interrupt priority threshold for context 0.
 * Only sources with priority > threshold are forwarded to the CPU. */
static inline void rv_plic_set_threshold(uint32_t threshold)
{
    RV_PLIC_THRESHOLD = threshold;
}

/* ─── claim / complete ────────────────────────────────────────────── */

/* Claim the highest-priority pending interrupt.
 * Returns the source ID (0 if no interrupt pending). */
static inline uint32_t rv_plic_claim(void)
{
    return RV_PLIC_CLAIM;
}

/* Signal completion of the interrupt with the given source ID. */
static inline void rv_plic_complete(uint32_t src)
{
    RV_PLIC_CLAIM = src;
}

/* ─── init helper ─────────────────────────────────────────────────── */

/* Convenience: enable a source with a given priority and enable the
 * PLIC external interrupt in mie.
 *
 *   src      – RV_PLIC_SRC_UART / _SPI / _I2C (or any 1-based ID)
 *   priority – 1..7  (higher = more urgent)
 */
static inline void rv_plic_init_source(uint32_t src, uint32_t priority)
{
    rv_plic_set_priority(src, priority);
    rv_plic_enable_source(src);
    rv_plic_set_threshold(0u);             /* accept everything > 0     */
    rv_irq_source_enable(RV_IRQ_MEIE);    /* enable external IRQ in mie */
}

#endif /* RV_PLIC_H */
