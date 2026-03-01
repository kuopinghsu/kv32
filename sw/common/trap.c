// ============================================================================
// File: trap.c
// Project: KV32 RISC-V Processor
// Description: Default machine-mode trap handler; delegates to kv_irq_dispatch()
//
// trap_handler() is a weak symbol that user code may override.
// When not overridden it calls kv_irq_dispatch() which routes each
// mcause value to the handler registered via kv_irq_register() or
// kv_exc_register().
// ============================================================================

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
#include "kv_irq.h"

/*
 * trap_handler – called by the trap_vector in start.S.
 *
 * Weak so that individual tests can still override it entirely if they
 * prefer the old single-function approach.
 */
__attribute__((weak))
void trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
    kv_irq_dispatch(mcause, mepc, mtval);
}

#ifdef __cplusplus
}
#endif
