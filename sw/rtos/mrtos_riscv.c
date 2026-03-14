/**
 * @file mrtos_riscv.c
 * @brief Mini-RTOS RISC-V / CLINT port.
 *
 * Provides:
 *  - CLINT-driven periodic tick at MRTOS_TICK_HZ
 *  - Machine-mode trap vector that saves/restores the full context and
 *    performs context switches on timer (MTI) and software (MSI) interrupts
 *  - Portable-layer API implementation (mrtos_port.h)
 *
 * ### Context-frame layout on the task stack (RV32, 132 bytes)
 *
 * | Offset | Content                     |
 * |--------|-----------------------------|
 * |   0    | mstatus                     |
 * |   4    | mepc                        |
 * |   8    | x1  (ra)                    |
 * |  12    | x3  (gp)                    |
 * |  16    | x4  (tp)                    |
 * |  20    | x5  (t0)                    |
 * |  24    | x6  (t1)                    |
 * |  28    | x7  (t2)                    |
 * |  32    | x8  (s0/fp)                 |
 * |  36    | x9  (s1)                    |
 * |  40    | x10 (a0)                    |
 * |  44    | x11 (a1)                    |
 * |  48    | x12 (a2)                    |
 * |  52    | x13 (a3)                    |
 * |  56    | x14 (a4)                    |
 * |  60    | x15 (a5)                    |
 * |  64    | x16 (a6)                    |
 * |  68    | x17 (a7)                    |
 * |  72    | x18 (s2)                    |
 * |  76    | x19 (s3)                    |
 * |  80    | x20 (s4)                    |
 * |  84    | x21 (s5)                    |
 * |  88    | x22 (s6)                    |
 * |  92    | x23 (s7)                    |
 * |  96    | x24 (s8)                    |
 * | 100    | x25 (s9)                    |
 * | 104    | x26 (s10)                   |
 * | 108    | x27 (s11)                   |
 * | 112    | x28 (t3)                    |
 * | 116    | x29 (t4)                    |
 * | 120    | x30 (t5)                    |
 * | 124    | x31 (t6)                    |
 * | 128    | x2  (original sp before frame) |
 *
 * @ingroup mrtos_port
 */

#include <stdint.h>
#include <stddef.h>
#include "mrtos.h"
#include "mrtos_port.h"
#include "kv_platform.h"
#include "kv_clint.h"
#include "kv_irq.h"

/* ════════════════════════════════════════════════════════════════════
 * Symbols exported to the kernel (mrtos_core.c)
 * ═══════════════════════════════════════════════════════════════════ */

/** Set to 1 by kernel to request a context switch on trap exit. */
extern volatile int      mrtos_ctx_switch_pending;
/** Pointer to the current task's sp field (where to save old sp). */
extern volatile void   **mrtos_ctx_old_sp_ptr;
/** New task's stack pointer (loaded on context switch). */
extern volatile void    *mrtos_ctx_new_sp;
/** New task stack-guard values to install after switching SP. */
extern volatile uint32_t mrtos_ctx_new_sguard_base;
extern volatile uint32_t mrtos_ctx_new_spmin;

/* ════════════════════════════════════════════════════════════════════
 * CLINT state
 * ═══════════════════════════════════════════════════════════════════ */

/** Last programmed mtimecmp value; updated in mrtos_port_ack_timer(). */
static uint64_t g_next_cmp;

/** Runtime tick period in mtime counts.  Default = MRTOS_TICKS_PER_SLOT. */
static volatile uint32_t g_tick_period = MRTOS_TICKS_PER_SLOT;

/* ════════════════════════════════════════════════════════════════════
 * C trap handler — called from mrtos_trap_vector
 * ═══════════════════════════════════════════════════════════════════ */

/**
 * @brief Machine-mode trap dispatcher for the RTOS.
 *
 * Handles MTI (tick), MSI (yield), and forwards all other causes to
 * kv_irq_dispatch() so that peripheral ISRs (UART, GPIO, ...) continue
 * to work normally.
 *
 * @param mcause  Machine cause register value.
 * @param mepc    Machine exception PC.
 * @param mtval   Machine trap value (unused for interrupt causes).
 */
void mrtos_trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
    if (mcause & 0x80000000u) {
        uint32_t code = mcause & 0x7FFFFFFFu;

        if (code == KV_CAUSE_MTI) {
            /* Machine timer interrupt — advance tick, program next compare. */
            mrtos_port_ack_timer();
            mrtos_tick();
            return;
        }

        if (code == KV_CAUSE_MSI) {
            /* Machine software interrupt — yield requested by a task.
             * Clear MSIP so the interrupt does not re-fire.
             * Use the CLINT helper's read-back so emulators such as Spike
             * observe the deassertion before we return from the trap. */
            kv_clint_msip_clear();
            /*
             * Edge case: mrtos_yield() set the task to READY but
             * do_schedule() found no higher-priority task to switch to.
             * Restore the current task to RUNNING state.
             */
            extern void mrtos_yield_msi_fixup(void);
            mrtos_yield_msi_fixup();
            return;
        }

        /* All other interrupts (MEI etc.) → standard dispatcher.
         * IRQ handlers don't modify mepc so a local frame is sufficient. */
        kv_trap_frame_t frame = {0};
        frame.mcause = mcause;
        frame.mepc   = mepc;
        frame.mtval  = mtval;
        kv_irq_dispatch(&frame);
    } else {
        /* Exception — forward to standard dispatcher.
         * Build a frame so exception handlers can update frame->mepc.
         * After dispatch, write back the (possibly updated) mepc to the
         * CSR; the RTOS epilogue assembly reads sp+4 (its own saved mepc
         * slot) — we update that by also calling write_csr_mepc so the
         * subsequent asm "lw t0, 4(sp) / csrw mepc, t0" restores to the
         * handler-chosen PC. */
        kv_trap_frame_t frame = {0};
        frame.mcause = mcause;
        frame.mepc   = mepc;
        frame.mtval  = mtval;
        kv_irq_dispatch(&frame);
        if (frame.mepc != mepc)
            write_csr_mepc(frame.mepc);
    }
}

/* ════════════════════════════════════════════════════════════════════
 * Trap vector — naked function, pure assembly
 *
 * This function must be 4-byte aligned so that mtvec (direct mode)
 * points to the correct location.  It saves the entire register
 * context, calls mrtos_trap_handler(), optionally performs a context
 * switch by repointing sp to the new task's frame, then restores the
 * (possibly new) context and executes mret.
 * ═══════════════════════════════════════════════════════════════════ */

void __attribute__((naked, aligned(4))) mrtos_trap_vector(void)
{
    __asm__ volatile (
        /* ── Allocate context frame ──────────────────────────────── */
        "addi  sp, sp, -132\n\t"

        /* ── Save all general-purpose registers ──────────────────── */
        "sw    x1,   8(sp)\n\t"   /* ra   */
        /* x2 (sp): computed below, saved at offset 128 */
        "sw    x3,  12(sp)\n\t"   /* gp   */
        "sw    x4,  16(sp)\n\t"   /* tp   */
        "sw    x5,  20(sp)\n\t"   /* t0   */
        "sw    x6,  24(sp)\n\t"   /* t1   */
        "sw    x7,  28(sp)\n\t"   /* t2   */
        "sw    x8,  32(sp)\n\t"   /* s0   */
        "sw    x9,  36(sp)\n\t"   /* s1   */
        "sw   x10,  40(sp)\n\t"   /* a0   */
        "sw   x11,  44(sp)\n\t"   /* a1   */
        "sw   x12,  48(sp)\n\t"   /* a2   */
        "sw   x13,  52(sp)\n\t"   /* a3   */
        "sw   x14,  56(sp)\n\t"   /* a4   */
        "sw   x15,  60(sp)\n\t"   /* a5   */
        "sw   x16,  64(sp)\n\t"   /* a6   */
        "sw   x17,  68(sp)\n\t"   /* a7   */
        "sw   x18,  72(sp)\n\t"   /* s2   */
        "sw   x19,  76(sp)\n\t"   /* s3   */
        "sw   x20,  80(sp)\n\t"   /* s4   */
        "sw   x21,  84(sp)\n\t"   /* s5   */
        "sw   x22,  88(sp)\n\t"   /* s6   */
        "sw   x23,  92(sp)\n\t"   /* s7   */
        "sw   x24,  96(sp)\n\t"   /* s8   */
        "sw   x25, 100(sp)\n\t"   /* s9   */
        "sw   x26, 104(sp)\n\t"   /* s10  */
        "sw   x27, 108(sp)\n\t"   /* s11  */
        "sw   x28, 112(sp)\n\t"   /* t3   */
        "sw   x29, 116(sp)\n\t"   /* t4   */
        "sw   x30, 120(sp)\n\t"   /* t5   */
        "sw   x31, 124(sp)\n\t"   /* t6   */

        /* Save original sp (= sp + 132) at offset 128. */
        "addi  t0, sp, 132\n\t"
        "sw    t0, 128(sp)\n\t"

        /* ── Save CSRs ───────────────────────────────────────────── */
        "csrr  t0, mepc\n\t"
        "sw    t0,   4(sp)\n\t"
        "csrr  t0, mstatus\n\t"
        "sw    t0,   0(sp)\n\t"

        /* ── Reload gp before entering C trap handler ───────────── */
        /*
         * gp (x3) is the RISC-V global pointer used for gp-relative
         * addressing of small-data globals.  It must equal
         * __global_pointer$ for C globals to be accessible.  The
         * interrupted task may have had any value in gp (including 0
         * if it was a freshly created task whose frame gp slot was
         * not yet written), so we reload it here using purely
         * PC-relative addressing (auipc + addi), which is independent
         * of the current gp.
         */
        ".option push\n\t"
        ".option norelax\n\t"
        "la    gp, __global_pointer$\n\t"
        ".option pop\n\t"

        /* ── Call C trap handler ─────────────────────────────────── */
        "csrr  a0, mcause\n\t"
        "csrr  a1, mepc\n\t"
        "csrr  a2, mtval\n\t"
        "call  mrtos_trap_handler\n\t"

        /* ── Context-switch check ────────────────────────────────── */
        /*
         * If mrtos_ctx_switch_pending != 0:
         *   1. Save current sp to *mrtos_ctx_old_sp_ptr (old task TCB).
         *   2. Load sp from mrtos_ctx_new_sp (new task frame).
         *   3. Clear the pending flag.
         */
        "la    t1, mrtos_ctx_switch_pending\n\t"
        "lw    t0, 0(t1)\n\t"
        "beqz  t0, .Lno_switch\n\t"

        "sw    zero, 0(t1)\n\t"          /* clear pending flag */

        /* Save old sp if mrtos_ctx_old_sp_ptr != NULL. */
        "la    t1, mrtos_ctx_old_sp_ptr\n\t"
        "lw    t2, 0(t1)\n\t"
        "beqz  t2, .Lskip_save\n\t"
        "sw    sp, 0(t2)\n\t"            /* *old_sp_ptr = current frame sp */

        ".Lskip_save:\n\t"
        /* Program SGUARD_BASE/SPMIN for the new task context first so
         * the subsequent SP write is checked against the incoming task guard,
         * not the outgoing task guard. */
        "la    t1, mrtos_ctx_new_sguard_base\n\t"
        "lw    t0, 0(t1)\n\t"
        "csrw  0x7cc, t0\n\t"
        "la    t1, mrtos_ctx_new_spmin\n\t"
        "lw    t0, 0(t1)\n\t"
        "csrw  0x7cd, t0\n\t"

        /* Load new sp. */
        "la    t1, mrtos_ctx_new_sp\n\t"
        "lw    sp, 0(t1)\n\t"            /* sp = new task frame */

        ".Lno_switch:\n\t"

        /* ── Restore CSRs from (possibly new) frame ──────────────── */
        "lw    t0,   0(sp)\n\t"
        "csrw  mstatus, t0\n\t"
        "lw    t0,   4(sp)\n\t"
        "csrw  mepc, t0\n\t"

        /* ── Restore all general-purpose registers ───────────────── */
        "lw    x1,   8(sp)\n\t"
        "lw    x3,  12(sp)\n\t"
        "lw    x4,  16(sp)\n\t"
        "lw    x5,  20(sp)\n\t"
        "lw    x6,  24(sp)\n\t"
        "lw    x7,  28(sp)\n\t"
        "lw    x8,  32(sp)\n\t"
        "lw    x9,  36(sp)\n\t"
        "lw   x10,  40(sp)\n\t"
        "lw   x11,  44(sp)\n\t"
        "lw   x12,  48(sp)\n\t"
        "lw   x13,  52(sp)\n\t"
        "lw   x14,  56(sp)\n\t"
        "lw   x15,  60(sp)\n\t"
        "lw   x16,  64(sp)\n\t"
        "lw   x17,  68(sp)\n\t"
        "lw   x18,  72(sp)\n\t"
        "lw   x19,  76(sp)\n\t"
        "lw   x20,  80(sp)\n\t"
        "lw   x21,  84(sp)\n\t"
        "lw   x22,  88(sp)\n\t"
        "lw   x23,  92(sp)\n\t"
        "lw   x24,  96(sp)\n\t"
        "lw   x25, 100(sp)\n\t"
        "lw   x26, 104(sp)\n\t"
        "lw   x27, 108(sp)\n\t"
        "lw   x28, 112(sp)\n\t"
        "lw   x29, 116(sp)\n\t"
        "lw   x30, 120(sp)\n\t"
        "lw   x31, 124(sp)\n\t"

        /*
         * Restore x2 (sp) last: this changes the stack pointer to the
         * task's original sp (before this trap frame was pushed).
         * After this, the frame is no longer accessible via sp.
         */
        "lw    x2, 128(sp)\n\t"

        /* ── Return to interrupted or new task ───────────────────── */
        "mret\n\t"
    );
}

/* ════════════════════════════════════════════════════════════════════
 * mrtos_port_start_first — naked, never returns
 * ═══════════════════════════════════════════════════════════════════ */

/**
 * @brief Load the first task's context frame and jump into it.
 *
 * Called once from mrtos_start() with interrupts disabled.
 * @p sp points to the initial frame prepared by init_stack_frame().
 */
void __attribute__((naked)) mrtos_port_start_first(void *sp)
{
    /* sp is passed in a0 per the RISC-V calling convention. */
    __asm__ volatile (
        /* Load the frame pointer from the argument. */
        "mv    sp, a0\n\t"

        /* Restore CSRs. */
        "lw    t0,   0(sp)\n\t"
        "csrw  mstatus, t0\n\t"
        "lw    t0,   4(sp)\n\t"
        "csrw  mepc, t0\n\t"

        /* Restore all general-purpose registers (excluding x2). */
        "lw    x1,   8(sp)\n\t"
        "lw    x3,  12(sp)\n\t"
        "lw    x4,  16(sp)\n\t"
        "lw    x5,  20(sp)\n\t"
        "lw    x6,  24(sp)\n\t"
        "lw    x7,  28(sp)\n\t"
        "lw    x8,  32(sp)\n\t"
        "lw    x9,  36(sp)\n\t"
        "lw   x10,  40(sp)\n\t"
        "lw   x11,  44(sp)\n\t"
        "lw   x12,  48(sp)\n\t"
        "lw   x13,  52(sp)\n\t"
        "lw   x14,  56(sp)\n\t"
        "lw   x15,  60(sp)\n\t"
        "lw   x16,  64(sp)\n\t"
        "lw   x17,  68(sp)\n\t"
        "lw   x18,  72(sp)\n\t"
        "lw   x19,  76(sp)\n\t"
        "lw   x20,  80(sp)\n\t"
        "lw   x21,  84(sp)\n\t"
        "lw   x22,  88(sp)\n\t"
        "lw   x23,  92(sp)\n\t"
        "lw   x24,  96(sp)\n\t"
        "lw   x25, 100(sp)\n\t"
        "lw   x26, 104(sp)\n\t"
        "lw   x27, 108(sp)\n\t"
        "lw   x28, 112(sp)\n\t"
        "lw   x29, 116(sp)\n\t"
        "lw   x30, 120(sp)\n\t"
        "lw   x31, 124(sp)\n\t"

        /* Restore x2 (sp) — frame is released, task stack pointer restored. */
        "lw    x2, 128(sp)\n\t"

        "mret\n\t"
    );
}

/* ════════════════════════════════════════════════════════════════════
 * Portable-layer API
 * ═══════════════════════════════════════════════════════════════════ */

void mrtos_port_init(void)
{
    /* Install the RTOS trap vector in direct mode. */
    uint32_t vec = (uint32_t)(uintptr_t)mrtos_trap_vector;
    /* Direct mode: bits[1:0] = 00 */
    __asm__ volatile ("csrw mtvec, %0" :: "r"(vec));

    /* Program first tick: mtime + one tick interval. */
    g_next_cmp = kv_clint_mtime() + (uint64_t)g_tick_period;
    kv_clint_set_mtimecmp(g_next_cmp);

    /* Enable machine timer and software interrupts. */
    kv_clint_timer_irq_enable();
    kv_irq_source_enable(KV_IRQ_MSIE);
}

void mrtos_port_ack_timer(void)
{
    /* Advance compare by one tick interval (no-drift for normal periods). */
    g_next_cmp += (uint64_t)g_tick_period;
    /* When tick_period < ISR latency, g_next_cmp can fall behind mtime,
     * causing an infinite stream of back-to-back timer interrupts and
     * starving all tasks.  Clamp to now+period in that case. */
    uint64_t now = kv_clint_mtime();
    if (g_next_cmp <= now)
        g_next_cmp = now + (uint64_t)g_tick_period;
    kv_clint_set_mtimecmp(g_next_cmp);
}

void mrtos_set_tick_period(uint32_t clint_ticks)
{
    uint32_t mstatus = mrtos_port_enter_critical();
    g_tick_period = clint_ticks;
    /* Reprogram mtimecmp immediately so the new rate takes effect now
     * rather than waiting for the currently-scheduled tick to fire. */
    g_next_cmp = kv_clint_mtime() + (uint64_t)clint_ticks;
    kv_clint_set_mtimecmp(g_next_cmp);
    mrtos_port_exit_critical(mstatus);
}

uint32_t mrtos_get_tick_period(void)
{
    return g_tick_period;
}

uint32_t mrtos_port_enter_critical(void)
{
    return kv_irq_disable();
}

void mrtos_port_exit_critical(uint32_t saved_mstatus)
{
    kv_irq_restore(saved_mstatus);
}

void mrtos_port_yield(void)
{
    /* Write 1 to CLINT MSIP; this raises the machine-software interrupt,
     * which fires as soon as the core leaves this function (next instruction
     * boundary with MIE=1).  The trap handler will clear MSIP and perform
     * the context switch.
     *
     * Use the CLINT helper rather than a raw MMIO store so the read-back
     * flushes the write through emulators that do not expose the pending
     * software interrupt until the store is globally visible. */
    kv_clint_msip_set();
    (void)KV_CLINT_MSIP;
}
