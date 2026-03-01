// ============================================================================
// File: kv_clint.h
// Project: KV32 RISC-V Processor
// Description: CLINT driver: mtime read/write, mtimecmp, MSIP software interrupt
//
// Hardware: axi_clint.sv at KV_CLINT_BASE (0x0200_0000).
// All functions are header-only inline; no separate .c required.
// ============================================================================

#ifndef KV_CLINT_H
#define KV_CLINT_H

#include <stdint.h>
#include "kv_platform.h"
#include "kv_irq.h"

/* ─── register accessors ──────────────────────────────────────────── */
#define KV_CLINT_MSIP         KV_REG32(KV_CLINT_BASE, KV_CLINT_MSIP_OFF)
#define KV_CLINT_MTIMECMP_LO  KV_REG32(KV_CLINT_BASE, KV_CLINT_MTIMECMP_LO_OFF)
#define KV_CLINT_MTIMECMP_HI  KV_REG32(KV_CLINT_BASE, KV_CLINT_MTIMECMP_HI_OFF)
#define KV_CLINT_MTIME_LO     KV_REG32(KV_CLINT_BASE, KV_CLINT_MTIME_LO_OFF)
#define KV_CLINT_MTIME_HI     KV_REG32(KV_CLINT_BASE, KV_CLINT_MTIME_HI_OFF)

/* ─── mtime ───────────────────────────────────────────────────────── */

/* Read the 64-bit hardware timer (safe against roll-over of the high word). */
static inline uint64_t kv_clint_mtime(void)
{
    uint32_t lo, hi, hi2;
    do {
        hi  = KV_CLINT_MTIME_HI;
        lo  = KV_CLINT_MTIME_LO;
        hi2 = KV_CLINT_MTIME_HI;
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

/* ─── mtimecmp ────────────────────────────────────────────────────── */

/* Write a new 64-bit compare value.
 * Writes hi=MAX first to prevent a spurious interrupt while updating lo. */
static inline void kv_clint_set_mtimecmp(uint64_t cmp)
{
    KV_CLINT_MTIMECMP_HI = 0xFFFFFFFFu;         /* prevent spurious IRQ  */
    KV_CLINT_MTIMECMP_LO = (uint32_t)cmp;
    KV_CLINT_MTIMECMP_HI = (uint32_t)(cmp >> 32);
}

/* Disable timer interrupts by setting compare to the maximum value. */
static inline void kv_clint_timer_disable(void)
{
    kv_clint_set_mtimecmp(0xFFFFFFFFFFFFFFFFULL);
}

/* Schedule a timer interrupt 'ticks' cycles from now. */
static inline void kv_clint_timer_set_rel(uint64_t ticks)
{
    kv_clint_set_mtimecmp(kv_clint_mtime() + ticks);
}

/* Enable the machine timer interrupt source in mie. */
static inline void kv_clint_timer_irq_enable(void)
{
    kv_irq_source_enable(KV_IRQ_MTIE);
}

/* Disable the machine timer interrupt source in mie. */
static inline void kv_clint_timer_irq_disable(void)
{
    kv_irq_source_disable(KV_IRQ_MTIE);
}

/* ─── software interrupt (MSIP) ───────────────────────────────────── */

/* Trigger a machine software interrupt. */
static inline void kv_clint_msip_set(void)
{
    KV_CLINT_MSIP = 1u;
}

/* Clear the machine software interrupt. */
static inline void kv_clint_msip_clear(void)
{
    KV_CLINT_MSIP = 0u;
    (void)KV_CLINT_MSIP;   /* read-back to ensure write is visible */
}

/* Enable the machine software interrupt source in mie. */
static inline void kv_clint_msip_irq_enable(void)
{
    kv_irq_source_enable(KV_IRQ_MSIE);
}

/* Disable the machine software interrupt source in mie. */
static inline void kv_clint_msip_irq_disable(void)
{
    kv_irq_source_disable(KV_IRQ_MSIE);
}

#endif /* KV_CLINT_H */
