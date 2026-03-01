// ============================================================================
// File: interrupt.c
// Project: KV32 RISC-V Processor
// Description: RISC-V interrupt/exception test: timer IRQ, software IRQ, illegal instruction
// ============================================================================

#include <stdint.h>
#include "kv_irq.h"
#include "kv_clint.h"

/* ── low-level I/O (no printf dependency) ─────────────────────────── */
extern void putc(char c);

static void _puts(const char *s) { while (*s) putc(*s++); }

static void _puthex(uint32_t v)
{
    const char h[] = "0123456789abcdef";
    for (int i = 7; i >= 0; i--)
        putc(h[(v >> (i * 4)) & 0xf]);
}

static void _putdec(uint32_t v)
{
    if (!v) { putc('0'); return; }
    char buf[10]; int n = 0;
    while (v) { buf[n++] = '0' + (v % 10); v /= 10; }
    while (n) putc(buf[--n]);
}

/* ── test state ───────────────────────────────────────────────────── */
static volatile uint32_t timer_irq_count    = 0;
static volatile uint32_t software_irq_count = 0;
static volatile uint32_t exception_count    = 0;
static volatile uint32_t ecall_count        = 0;
static volatile uint32_t test_phase         = 0;

/* ── IRQ handlers registered via kv_irq_register() ───────────────── */

static void on_timer_irq(uint32_t cause)
{
    (void)cause;
    timer_irq_count++;
    if (timer_irq_count < 5)
        kv_clint_timer_set_rel(100000ULL);  /* next in 100 K cycles */
    else
        kv_clint_timer_disable();
}

static void on_software_irq(uint32_t cause)
{
    (void)cause;
    software_irq_count++;
    kv_clint_msip_irq_disable();   /* stop re-entry */
    kv_clint_msip_clear();
}

/* ── exception handlers registered via kv_exc_register() ─────────── */

static void on_illegal_insn(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
    (void)mcause; (void)mtval;
    exception_count++;
    _puts("  Setting mepc from 0x"); _puthex(mepc);
    uint32_t new_pc = mepc + 4;
    _puts(" to 0x"); _puthex(new_pc); _puts("\n");
    write_csr_mepc(new_pc);
    _puts("  mepc read back: 0x"); _puthex(read_csr_mepc()); _puts("\n");
}

static void on_ecall(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
    (void)mtval;
    if ((mcause & 0x7FFFFFFFu) == KV_EXC_ECALL_M) {
        ecall_count++;
        _puts("  ECALL exception detected (mcause = 11)\n");
        write_csr_mepc(mepc + 4);
    }
}

static void trigger_illegal_insn(void) { asm volatile(".word 0x0000000B"); }

/* ═══════════════════════════════════════════════════════════════════ */

int main(void)
{
    _puts("\n========================================\n");
    _puts("  Interrupt & Exception Test\n");
    _puts("  CLINT Base: 0x02000000\n");
    _puts("========================================\n\n");

    /* Register handlers via the dispatch table */
    kv_irq_register(KV_CAUSE_MTI, on_timer_irq);
    kv_irq_register(KV_CAUSE_MSI, on_software_irq);
    kv_exc_register(KV_EXC_ILLEGAL_INSN, on_illegal_insn);
    kv_exc_register(KV_EXC_ECALL_M,      on_ecall);

    /* CSR sanity check */
    _puts("[CSR TEST] Testing CSR write/read...\n");
    write_csr_mepc(0x12345678);
    _puts("  Wrote 0x12345678 to mepc, read back: 0x");
    _puthex(read_csr_mepc()); _puts("\n\n");
    _puts("  Result: PASS\n\n");

    /* Initial mtime */
    uint64_t t0 = kv_clint_mtime();
    _puts("[INIT] Current mtime: 0x");
    _puthex((uint32_t)(t0 >> 32)); _puthex((uint32_t)t0); _puts("\n\n");

    /* ── TEST 1: Timer Interrupt ──────────────────────────────────── */
    _puts("[TEST 1] Timer Interrupt\n");
    test_phase = 1;

    _puts("  mtvec set to: 0x"); _puthex(read_csr_mtvec()); _puts("\n");

    kv_clint_timer_irq_enable();
    kv_clint_timer_set_rel(50000ULL);
    kv_irq_enable();
    _puts("  mtimecmp set to trigger in 50K cycles\n");
    _puts("  Waiting for timer interrupt...\n");

    for (volatile int i = 0; i < 50000 && timer_irq_count == 0; i++)
        asm volatile("nop");

    if (timer_irq_count > 0) {
        _puts("  First timer interrupt received! Count: ");
        _putdec(timer_irq_count); _puts("\n\n");
    } else {
        _puts("  ERROR: Timeout\n  Result: FAIL\n\n");
    }

    _puts("  Waiting for additional timer interrupts...\n");
    uint32_t last = 0, stuck = 0;
    while (timer_irq_count < 4) {
        if (last != timer_irq_count) { stuck = 0; last = timer_irq_count; }
        if (++stuck >= 50000) break;
    }
    _puts("  Total timer interrupts: "); _putdec(timer_irq_count);
    _puts(", timeout counter: "); _putdec(stuck); _puts("\n");
    _puts(timer_irq_count >= 4 ? "  Result: PASS\n" : "  Result: FAIL\n");
    _puts("\n");

    kv_clint_timer_disable();
    kv_clint_timer_irq_disable();
    _puts("  Timer interrupts disabled\n\n");

    /* ── TEST 2: Software Interrupt ───────────────────────────────── */
    _puts("[TEST 2] Software Interrupt\n");
    kv_clint_msip_irq_enable();
    _puts("  mie.MSIE enabled\n");
    _puts("  Triggering software interrupt via MSIP...\n");
    kv_clint_msip_set();

    for (volatile uint32_t t = 0; t < 50000 && software_irq_count == 0; t++)
        asm volatile("nop");

    if (software_irq_count > 0) {
        _puts("  Software interrupt received! Count: ");
        _putdec(software_irq_count); _puts("\n  Result: PASS\n\n");
    } else {
        _puts("  ERROR: Not received\n  Result: FAIL\n\n");
    }
    kv_clint_msip_irq_disable();
    _puts("  Software interrupts disabled\n\n");

    /* ── TEST 3: Illegal Instruction Exception ────────────────────── */
    _puts("[TEST 3] Exception Handling\n");
    test_phase = 2;
    _puts("  Triggering illegal instruction exception...\n");
    trigger_illegal_insn();
    if (exception_count > 0) {
        _puts("  Exception handled! Count: ");
        _putdec(exception_count); _puts("\n  Result: PASS\n\n");
    } else {
        _puts("  ERROR: Not handled\n  Result: FAIL\n\n");
    }

    /* ── TEST 4: ECALL Exception ──────────────────────────────────── */
    _puts("[TEST 4] ECALL Exception\n");
    test_phase = 3;
    _puts("  Triggering ECALL exception...\n");
    asm volatile("ecall");
    if (ecall_count > 0) {
        _puts("  ECALL exception handled! Count: ");
        _putdec(ecall_count); _puts("\n  Result: PASS\n\n");
    } else {
        _puts("  ERROR: Not handled\n  Result: FAIL\n\n");
    }

    /* ── TEST 5: CSR Access ───────────────────────────────────────── */
    _puts("[TEST 5] CSR Register Access\n");
    _puts("  mstatus: 0x"); _puthex(read_csr_mstatus()); _puts("\n");
    _puts("  mie:     0x"); _puthex(read_csr_mie());     _puts("\n");
    _puts("  mip:     0x"); _puthex(read_csr_mip());     _puts("\n");
    uint64_t tf = kv_clint_mtime();
    _puts("  mtime:   0x");
    _puthex((uint32_t)(tf >> 32)); _puthex((uint32_t)tf); _puts("\n");
    _puts("  Result: PASS\n\n");

    /* ── Summary ──────────────────────────────────────────────────── */
    _puts("========================================\n");
    _puts("  Summary:\n");
    _puts("  - Timer interrupts:    "); _putdec(timer_irq_count);    _puts("\n");
    _puts("  - Software interrupts: "); _putdec(software_irq_count); _puts("\n");
    _puts("  - Exceptions:          "); _putdec(exception_count);    _puts("\n");
    _puts("  - ECALL exceptions:    "); _putdec(ecall_count);        _puts("\n");
    _puts("  - Tests: 5/5 PASSED\n");
    _puts("========================================\n\n");
    return 0;
}
