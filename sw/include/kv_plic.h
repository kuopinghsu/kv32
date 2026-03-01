// ============================================================================
// File: kv_plic.h
// Project: KV32 RISC-V Processor
// Description: PLIC driver: interrupt enable, threshold, claim/complete for hart 0
//
// Hardware: axi_plic.sv at KV_PLIC_BASE.
// Supports a single hart (hart 0, machine-mode context 0).
// IRQ source IDs are defined in kv_platform.h (KV_PLIC_SRC_*).
// ============================================================================

#ifndef KV_PLIC_H
#define KV_PLIC_H

#include <stdint.h>
#include "kv_platform.h"
#include "kv_irq.h"

/* Maximum number of interrupt sources supported by this driver */
#define KV_PLIC_MAX_SOURCES  32u

/* ─── register accessors ──────────────────────────────────────────── */

/* Source priority register for source n (1-based) */
#define KV_PLIC_PRIORITY(n) \
    KV_REG32(KV_PLIC_BASE, KV_PLIC_PRIORITY_OFF + (uint32_t)(n) * 4u)

/* Pending bit array (32 sources in word 0) */
#define KV_PLIC_PENDING     KV_REG32(KV_PLIC_BASE, KV_PLIC_PENDING_OFF)

/* Enable bits for context 0 */
#define KV_PLIC_ENABLE      KV_REG32(KV_PLIC_BASE, KV_PLIC_ENABLE_OFF)

/* Priority threshold for context 0 */
#define KV_PLIC_THRESHOLD   KV_REG32(KV_PLIC_BASE, KV_PLIC_THRESHOLD_OFF)

/* Claim / complete register for context 0 */
#define KV_PLIC_CLAIM       KV_REG32(KV_PLIC_BASE, KV_PLIC_CLAIM_OFF)

/* ─── source-level control ────────────────────────────────────────── */

/* Set the priority for a PLIC source (1..15; 0 = effectively disabled). */
static inline void kv_plic_set_priority(uint32_t src, uint32_t priority)
{
    KV_PLIC_PRIORITY(src) = priority;
}

/* Enable a PLIC source for context 0. */
static inline void kv_plic_enable_source(uint32_t src)
{
    KV_PLIC_ENABLE |= (1u << src);
}

/* Disable a PLIC source for context 0. */
static inline void kv_plic_disable_source(uint32_t src)
{
    KV_PLIC_ENABLE &= ~(1u << src);
}

/* Check whether a source has a pending interrupt. */
static inline int kv_plic_is_pending(uint32_t src)
{
    return (KV_PLIC_PENDING >> src) & 1u;
}

/* ─── threshold ───────────────────────────────────────────────────── */

/* Set the interrupt priority threshold for context 0.
 * Only sources with priority > threshold are forwarded to the CPU. */
static inline void kv_plic_set_threshold(uint32_t threshold)
{
    KV_PLIC_THRESHOLD = threshold;
}

/* ─── claim / complete ────────────────────────────────────────────── */

/* Claim the highest-priority pending interrupt.
 * Returns the source ID (0 if no interrupt pending). */
static inline uint32_t kv_plic_claim(void)
{
    return KV_PLIC_CLAIM;
}

/* Signal completion of the interrupt with the given source ID. */
static inline void kv_plic_complete(uint32_t src)
{
    KV_PLIC_CLAIM = src;
}

/* ─── init helper ─────────────────────────────────────────────────── */

/* Convenience: enable a source with a given priority and enable the
 * PLIC external interrupt in mie.
 *
 *   src      – KV_PLIC_SRC_UART / _SPI / _I2C (or any 1-based ID)
 *   priority – 1..15  (higher = more urgent; 0 = effectively disabled)
 */
static inline void kv_plic_init_source(uint32_t src, uint32_t priority)
{
    kv_plic_set_priority(src, priority);
    kv_plic_enable_source(src);
    kv_plic_set_threshold(0u);             /* accept everything > 0     */
    kv_irq_source_enable(KV_IRQ_MEIE);    /* enable external IRQ in mie */
}

#endif /* KV_PLIC_H */
