/*
 * rv_clint.h – Core-Local Interrupt Controller (CLINT) driver
 *
 * Provides inline helpers for:
 *   - Reading/writing 64-bit mtime safely
 *   - Setting mtimecmp to schedule timer interrupts
 *   - Triggering/clearing software interrupts via MSIP
 */
#ifndef RV_CLINT_H
#define RV_CLINT_H

#include <stdint.h>
#include "rv_platform.h"
#include "rv_irq.h"

/* ─── register accessors ──────────────────────────────────────────── */
#define RV_CLINT_MSIP         RV_REG32(RV_CLINT_BASE, RV_CLINT_MSIP_OFF)
#define RV_CLINT_MTIMECMP_LO  RV_REG32(RV_CLINT_BASE, RV_CLINT_MTIMECMP_LO_OFF)
#define RV_CLINT_MTIMECMP_HI  RV_REG32(RV_CLINT_BASE, RV_CLINT_MTIMECMP_HI_OFF)
#define RV_CLINT_MTIME_LO     RV_REG32(RV_CLINT_BASE, RV_CLINT_MTIME_LO_OFF)
#define RV_CLINT_MTIME_HI     RV_REG32(RV_CLINT_BASE, RV_CLINT_MTIME_HI_OFF)

/* ─── mtime ───────────────────────────────────────────────────────── */

/* Read the 64-bit hardware timer (safe against roll-over of the high word). */
static inline uint64_t rv_clint_mtime(void)
{
    uint32_t lo, hi, hi2;
    do {
        hi  = RV_CLINT_MTIME_HI;
        lo  = RV_CLINT_MTIME_LO;
        hi2 = RV_CLINT_MTIME_HI;
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

/* ─── mtimecmp ────────────────────────────────────────────────────── */

/* Write a new 64-bit compare value.
 * Writes hi=MAX first to prevent a spurious interrupt while updating lo. */
static inline void rv_clint_set_mtimecmp(uint64_t cmp)
{
    RV_CLINT_MTIMECMP_HI = 0xFFFFFFFFu;         /* prevent spurious IRQ  */
    RV_CLINT_MTIMECMP_LO = (uint32_t)cmp;
    RV_CLINT_MTIMECMP_HI = (uint32_t)(cmp >> 32);
}

/* Disable timer interrupts by setting compare to the maximum value. */
static inline void rv_clint_timer_disable(void)
{
    rv_clint_set_mtimecmp(0xFFFFFFFFFFFFFFFFULL);
}

/* Schedule a timer interrupt 'ticks' cycles from now. */
static inline void rv_clint_timer_set_rel(uint64_t ticks)
{
    rv_clint_set_mtimecmp(rv_clint_mtime() + ticks);
}

/* Enable the machine timer interrupt source in mie. */
static inline void rv_clint_timer_irq_enable(void)
{
    rv_irq_source_enable(RV_IRQ_MTIE);
}

/* Disable the machine timer interrupt source in mie. */
static inline void rv_clint_timer_irq_disable(void)
{
    rv_irq_source_disable(RV_IRQ_MTIE);
}

/* ─── software interrupt (MSIP) ───────────────────────────────────── */

/* Trigger a machine software interrupt. */
static inline void rv_clint_msip_set(void)
{
    RV_CLINT_MSIP = 1u;
}

/* Clear the machine software interrupt. */
static inline void rv_clint_msip_clear(void)
{
    RV_CLINT_MSIP = 0u;
    (void)RV_CLINT_MSIP;   /* read-back to ensure write is visible */
}

/* Enable the machine software interrupt source in mie. */
static inline void rv_clint_msip_irq_enable(void)
{
    rv_irq_source_enable(RV_IRQ_MSIE);
}

/* Disable the machine software interrupt source in mie. */
static inline void rv_clint_msip_irq_disable(void)
{
    rv_irq_source_disable(RV_IRQ_MSIE);
}

#endif /* RV_CLINT_H */
