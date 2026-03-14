// ============================================================================
// File: kv_irq.c
// Project: KV32 RISC-V Processor
// Description: Machine-mode IRQ / exception dispatch table implementation
//
// Implements the per-cause handler registration table used by the
// default trap_handler() in trap.c.  Handlers are registered with
// kv_irq_register() / kv_exc_register() (see kv_irq.h).
// ============================================================================

#include <stdint.h>
#include "kv_irq.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ── default handlers ─────────────────────────────────────────────── */

/* Low-level character output used before printf is available. */
extern void putc(char c);

static void _puts(const char *s) { while (*s) putc(*s++); }

static void _puthex(uint32_t v)
{
    const char h[] = "0123456789abcdef";
    _puts("0x");
    for (int i = 7; i >= 0; i--)
        putc(h[(v >> (i * 4)) & 0xf]);
}

static void _default_irq(uint32_t cause)
{
    _puts("[kv_irq] unhandled interrupt, cause="); _puthex(cause); _puts("\n");
}

static void _default_exc(kv_trap_frame_t *frame)
{
    _puts("\n=== EXCEPTION ===\n");
    _puts("mcause: "); _puthex(frame->mcause); _puts("\n");
    _puts("mepc:   "); _puthex(frame->mepc);   _puts("\n");
    _puts("mtval:  "); _puthex(frame->mtval);  _puts("\n");
    _puts("Halted.\n");
    while (1) {}
}

/* ── dispatch tables ──────────────────────────────────────────────── */

/* Interrupt causes 0..15 (MSB stripped from mcause) */
#define _IRQ_MAX 16u
static kv_irq_handler_t _irq_table[_IRQ_MAX];

/* Exception causes 0..31 (includes KV32 custom cause 16) */
#define _EXC_MAX 32u
static kv_exc_handler_t _exc_table[_EXC_MAX];

/* ── registration ─────────────────────────────────────────────────── */

void kv_irq_register(uint32_t cause, kv_irq_handler_t handler)
{
    if (cause < _IRQ_MAX)
        _irq_table[cause] = handler;
}

void kv_exc_register(uint32_t cause, kv_exc_handler_t handler)
{
    if (cause < _EXC_MAX)
        _exc_table[cause] = handler;
}

/* ── dispatcher ───────────────────────────────────────────────────── */

void kv_irq_dispatch(kv_trap_frame_t *frame)
{
    uint32_t mcause = frame->mcause;
    if (mcause & 0x80000000u) {
        /* Interrupt */
        uint32_t code = mcause & 0x7FFFFFFFu;
        if (code < _IRQ_MAX && _irq_table[code])
            _irq_table[code](code);
        else
            _default_irq(code);
    } else {
        /* Exception */
        uint32_t code = mcause & 0x7FFFFFFFu;
        if (code < _EXC_MAX && _exc_table[code])
            _exc_table[code](frame);
        else
            _default_exc(frame);
    }
}

#ifdef __cplusplus
}
#endif
