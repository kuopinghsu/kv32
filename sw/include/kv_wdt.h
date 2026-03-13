/**
 * @file kv_wdt.h
 * @brief KV32 Hardware Watchdog Timer (WDT) driver
 *
 * The WDT counts down from the LOAD value. When the counter reaches zero:
 *   - INTR_EN=1: fires a PLIC interrupt (KV_PLIC_SRC_WDT) and disables itself.
 *   - INTR_EN=0: terminates simulation with exit code 2 (panic mode).
 *
 * Firmware must call kv_wdt_kick() periodically to reload the counter.
 */
#ifndef KV_WDT_H
#define KV_WDT_H

#include <stdint.h>
#include "kv_platform.h"

static inline void kv_wdt_start(uint32_t load, int intr_en) {
    /* Program the reload value */
    KV_REG32(KV_WDT_BASE, KV_WDT_LOAD_OFF) = load;
    /* Preload COUNT from LOAD (RTL resets COUNT to 0; KICK avoids immediate expiry) */
    KV_REG32(KV_WDT_BASE, KV_WDT_KICK_OFF) = 1u;
    /* Clear any stale interrupt status */
    KV_REG32(KV_WDT_BASE, KV_WDT_STATUS_OFF) = (1u << KV_WDT_STATUS_INT_BIT);
    /* Enable: set EN + optionally INTR_EN */
    KV_REG32(KV_WDT_BASE, KV_WDT_CTRL_OFF) =
        (1u << KV_WDT_CTRL_EN_BIT) |
        ((intr_en ? 1u : 0u) << KV_WDT_CTRL_INTR_EN_BIT);
}

static inline void kv_wdt_kick(void) {
    KV_REG32(KV_WDT_BASE, KV_WDT_KICK_OFF) = 1u;
}

static inline void kv_wdt_stop(void) {
    KV_REG32(KV_WDT_BASE, KV_WDT_CTRL_OFF) &= ~(1u << KV_WDT_CTRL_EN_BIT);
}

static inline void kv_wdt_clear_int(void) {
    KV_REG32(KV_WDT_BASE, KV_WDT_STATUS_OFF) = (1u << KV_WDT_STATUS_INT_BIT);
}

#endif /* KV_WDT_H */
