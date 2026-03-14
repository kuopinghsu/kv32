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
 * trap_handler – called by the trap_vector in start.S with a pointer to the
 * saved register frame (kv_trap_frame_t).  Exception handlers registered via
 * kv_exc_register() receive the same frame pointer and may update frame->mepc
 * to redirect the return PC.
 *
 * Weak so that individual tests can still override it entirely.
 */
__attribute__((weak))
void trap_handler(kv_trap_frame_t *frame)
{
    kv_irq_dispatch(frame);
}

#ifdef __cplusplus
}
#endif
