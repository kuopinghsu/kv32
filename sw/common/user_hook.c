// ============================================================================
// File: user_hook.c
// Project: KV32 RISC-V Processor
// Description: Default (weak) user_hook() — called from start.S immediately
//              before main().  Starts a periodic timer that pets the hardware
//              watchdog, preventing an unintentional reset during normal test
//              execution.
//
// Applications that need a different WDT policy (e.g. the RTOS test, which
// verifies that the WDT fires on task starvation) provide their own strong
// definition of user_hook() and the linker will use that instead.
//
// Default behaviour:
//   1. Register a PLIC MEI handler that clears the timer interrupt and kicks
//      the WDT on every timer ch0 compare match.
//   2. Start timer ch0 at period = 2000 cycles (no prescaler).
//   3. Start the WDT in IRQ mode (INTR_EN=1) with LOAD = 20000 cycles —
//      ten times the timer period, giving ample margin if an interrupt is
//      delayed by a long critical section.
// ============================================================================

#include <stdint.h>
#include "kv_platform.h"
#include "kv_irq.h"
#include "kv_plic.h"
#include "kv_timer.h"
#include "kv_wdt.h"

/* ── MEI handler: clear timer ch0 interrupt and kick the WDT ─────────────── */
static void wdt_keeper_handler(uint32_t cause)
{
    (void)cause;
    uint32_t src = kv_plic_claim();
    if (src == (uint32_t)KV_PLIC_SRC_TIMER0) {
        kv_timer_clear_int(1u << 0);  /* Clear channel 0 interrupt (W1C) */
        kv_wdt_clear_int();           /* Clear any WDT IRQ status before reloading */
        kv_wdt_kick();
    }
    kv_plic_complete(src);
}

/* ── Default weak user_hook ──────────────────────────────────────────────── */
__attribute__((weak))
void user_hook(void)
{
    /* Register the external-interrupt handler and enable the PLIC source. */
    kv_irq_register(KV_CAUSE_MEI, wdt_keeper_handler);
    kv_plic_init_source(KV_PLIC_SRC_TIMER0, 1);

    /* Enable global interrupts (sets mstatus.MIE). */
    kv_irq_enable();

    /* Start timer ch0: period = 2000 cycles, prescaler = 0 (1:1). */
    kv_timer_start(0, 2000u, 0);

    /* Start the WDT in interrupt mode: LOAD = 20000 cycles, INTR_EN = 1. */
    kv_wdt_start(20000u, 1);
}
