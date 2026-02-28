/*
 * kv_irq.c – Machine-mode IRQ / exception dispatch table
 *
 * Implements the dispatch table that the default trap_handler fills in
 * and calls into.  Each entry is a weak pointer; user code overrides it
 * by calling kv_irq_register() / kv_exc_register().
 *
 * This file is compiled as part of COMMON_SRCS (see top-level Makefile).
 */

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

static void _default_exc(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
    _puts("\n=== EXCEPTION ===\n");
    _puts("mcause: "); _puthex(mcause); _puts("\n");
    _puts("mepc:   "); _puthex(mepc);   _puts("\n");
    _puts("mtval:  "); _puthex(mtval);  _puts("\n");
    _puts("Halted.\n");
    while (1) {}
}

/* ── dispatch tables ──────────────────────────────────────────────── */

/* Interrupt causes 0..15 (MSB stripped from mcause) */
#define _IRQ_MAX 16u
static kv_irq_handler_t _irq_table[_IRQ_MAX];

/* Exception causes 0..15 */
#define _EXC_MAX 16u
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

void kv_irq_dispatch(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
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
            _exc_table[code](mcause, mepc, mtval);
        else
            _default_exc(mcause, mepc, mtval);
    }
}

#ifdef __cplusplus
}
#endif
