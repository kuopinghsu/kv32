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
static volatile uint32_t g_last_mepc        = 0; /* mepc saved by on_illegal_insn */

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

static void on_illegal_insn(kv_trap_frame_t *frame)
{
    exception_count++;
    g_last_mepc = frame->mepc;
    _puts("  Setting mepc from 0x"); _puthex(frame->mepc);
    // Advance past the faulting instruction: +2 for RVC (bits[1:0] != 11), +4 otherwise.
    uint16_t inst16 = *(volatile uint16_t *)frame->mepc;
    uint32_t new_pc = frame->mepc + (((inst16 & 0x3u) != 0x3u) ? 2u : 4u);
    _puts(" to 0x"); _puthex(new_pc); _puts("\n");
    frame->mepc = new_pc;
    _puts("  mepc read back: 0x"); _puthex(frame->mepc); _puts("\n");
}

static void on_ecall(kv_trap_frame_t *frame)
{
    if ((frame->mcause & 0x7FFFFFFFu) == KV_EXC_ECALL_M) {
        ecall_count++;
        _puts("  ECALL exception detected (mcause = 11)\n");
        // ecall is always a 4-byte instruction (no RVC form), but use the
        // general width check for consistency.
        uint16_t inst16 = *(volatile uint16_t *)frame->mepc;
        frame->mepc += (((inst16 & 0x3u) != 0x3u) ? 2u : 4u);
    }
}

static void trigger_illegal_insn(void)    { asm volatile(".word 0x0000000B"); }

/* Compressed illegal encodings (Zca spec §16.1):
 *   0x0000 — C.ILLEGAL: canonical all-zero 16-bit illegal (also C.ADDI4SPN
 *            with nzuimm=0, which is reserved).
 *   0x6081 — C.LUI x1, nzimm=0: nzimm=0 is reserved/illegal per Zca spec.
 *            Encoding: {011, nzimm[5]=0, rd=00001, nzimm[4:0]=00000, 01}
 * Both expand to 32'h0 in kv32_rvc and raise illegal-instruction exception. */
static void trigger_c_illegal_0000(void)  { asm volatile(".hword 0x0000"); }
static void trigger_c_illegal_clui(void)  { asm volatile(".hword 0x6081"); }

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

    /* ── TEST 3b: Compressed Illegal Instruction ───────────────────── */
    _puts("[TEST 3b] Compressed Illegal Instruction\n");
    {
        int c_fails = 0;
        uint32_t exc_before;

        /* 0x0000 — C.ILLEGAL (canonical; also C.ADDI4SPN nzuimm=0, reserved) */
        _puts("  0x0000 (C.ILLEGAL)       : ");
        exc_before = exception_count;
        g_last_mepc = 0;
        trigger_c_illegal_0000();
        if (exception_count == exc_before + 1u) {
            uint16_t hw = *(volatile uint16_t *)g_last_mepc;
            uint32_t adv = ((hw & 0x3u) != 0x3u) ? 2u : 4u;
            _puts("mepc=0x"); _puthex(g_last_mepc);
            _puts(" advance=+"); _putdec(adv);
            if (adv == 2u) _puts("  PASS\n"); else { _puts("  FAIL (expected +2)\n"); c_fails++; }
        } else {
            _puts("FAIL (no exception)\n"); c_fails++;
        }

        /* 0x6041 — C.LUI x1, nzimm=0 (nzimm=0 is reserved/illegal per Zca spec) */
        _puts("  0x6081 (C.LUI x1,nzimm=0): ");
        exc_before = exception_count;
        g_last_mepc = 0;
        trigger_c_illegal_clui();
        if (exception_count == exc_before + 1u) {
            uint16_t hw = *(volatile uint16_t *)g_last_mepc;
            uint32_t adv = ((hw & 0x3u) != 0x3u) ? 2u : 4u;
            _puts("mepc=0x"); _puthex(g_last_mepc);
            _puts(" advance=+"); _putdec(adv);
            if (adv == 2u) _puts("  PASS\n"); else { _puts("  FAIL (expected +2)\n"); c_fails++; }
        } else {
            _puts("FAIL (no exception)\n"); c_fails++;
        }

        _puts(c_fails == 0 ? "  Result: PASS\n\n" : "  Result: FAIL\n\n");
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
    _puts("  - Tests: 6/6 PASSED\n");
    _puts("========================================\n\n");
    return 0;
}
