// ============================================================================
// File: user_hook.c
// Project: KV32 RISC-V Processor
// Description: Default (weak) user_hook() — called from start.S immediately
//              before main().
//
// The default implementation is a no-op.  Tests or applications that need
// pre-main peripheral initialisation (e.g. WDT keepalive, board bringup)
// supply a strong definition of user_hook() in their own source file and the
// linker will prefer that over this weak fallback.
//
// Examples of strong overrides already in the tree:
//   sw/wdt/wdt.c        — empty body (WDT under full test control)
//   sw/rtos/rtos_test.c — starts RTOS-specific timer/WDT configuration
//
// IMPORTANT: do NOT start PLIC-MEI-sourced peripherals (timers, WDT, etc.)
// from this default hook.  Many tests register their own MEI handler and
// would be broken by a pre-registered MEI handler that fires timer0/WDT
// interrupts they do not know how to dismiss.
// ============================================================================

#ifdef __cplusplus
extern "C" {
#endif

/* ── Default weak user_hook: no-op ──────────────────────────────────────── */
__attribute__((weak))
void user_hook(void)
{
    /* Intentionally empty.
     * Each test enables only the peripherals/interrupts it needs. */
}

#ifdef __cplusplus
}
#endif
