/*
 * trap.c – Default trap handler for RISC-V exceptions and interrupts.
 *
 * The default trap_handler is a *weak* symbol.  User code can override
 * it by defining a non-weak trap_handler().
 *
 * When not overridden, trap_handler() delegates to rv_irq_dispatch()
 * which routes each cause to the handler registered with
 * rv_irq_register() / rv_exc_register() (see rv_irq.h).
 * This allows fine-grained per-cause hooks without replacing the whole
 * trap entry point.
 */

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
#include "rv_irq.h"

/*
 * trap_handler – called by the trap_vector in start.S.
 *
 * Weak so that individual tests can still override it entirely if they
 * prefer the old single-function approach.
 */
__attribute__((weak))
void trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
    rv_irq_dispatch(mcause, mepc, mtval);
}

#ifdef __cplusplus
}
#endif
