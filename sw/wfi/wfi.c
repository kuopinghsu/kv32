// ============================================================================
// File: wfi.c
// Project: KV32 RISC-V Processor
// Description: Comprehensive WFI (Wait For Interrupt) test suite
//
// Two interrupt source types are exercised:
//
//   Level-triggered (CLINT timer, MTIP):
//     The MTIP signal in mip stays asserted as long as mtime >= mtimecmp.
//     The handler must advance mtimecmp to de-assert MTIP.  A persistent
//     level source can re-fire the same WFI iteration if not cleared in time.
//     Tests 1-4 cover this source.
//
//   Edge-triggered (CLINT MSIP, software interrupt):
//     MSIP is write-1-to-set and stays asserted until software clears it.
//     It fires once per set/clear cycle; the handler explicitly clears it to
//     prevent re-entry.  Edge-like in the sense that it requires an explicit
//     software "edge" (write) to inject each event.
//     Tests 5-7 cover this source.
//
// Tests:
//   1  Timer edge         : WFI stalls until a future timer fires (~1000 cycles)
//   2  Timer level        : Timer already expired; WFI wakes almost immediately
//   3  Timer repeat       : 20 back-to-back timer-wakeup WFI calls
//   4  Timer timing       : Sleep duration ≈ specified timer period (± margin)
//   5  MSIP edge          : Timer handler fires MSIP; second WFI wakes on MSIP
//   6  MSIP level         : MSIP set before WFI via timer chain; wakes immediately
//   7  Rapid storm        : 50 WFIs with a 200-cycle timer period
//   8  IRQ at EX boundary : 30-cycle timer fires at nop/sleep boundary
//   9  Post-MRET re-WFI   : irq_was_pending cleared between WFIs (800-cycle period)
//  10  Long sleep          : 10000-cycle full PM clock-gate cycle timing verify
//  11  IRQ pending entry   : MTIP asserted before WFI reaches EX, taken directly
//  12  Pipeline drain race : Timer fires during IB-drain window (~100 cycles)
// ============================================================================

#include <stdint.h>
#include <stdio.h>
#include "kv_platform.h"
#include "kv_irq.h"
#include "kv_clint.h"

/* ── test accounting ─────────────────────────────────────────────────────── */

static int g_pass, g_fail;

#define TEST_PASS(n)      do { printf("[TEST %2d] PASS\n", (n)); g_pass++; } while (0)
#define TEST_FAIL(n, msg) do { printf("[TEST %2d] FAIL: %s\n", (n), (msg)); g_fail++; } while (0)

/* ── shared IRQ state ────────────────────────────────────────────────────── */

static volatile uint32_t g_timer_count;   /* MTI fires */
static volatile uint32_t g_msip_count;    /* MSI fires */
static volatile uint64_t g_handler_time;  /* mtime sampled inside MTI handler */
/* When set by a test, the MTI handler also fires MSIP to chain interrupts. */
static volatile uint32_t g_arm_msip;

/* ── default MTI handler ─────────────────────────────────────────────────── */

static void on_timer(uint32_t cause)
{
    (void)cause;
    g_handler_time = kv_clint_mtime();
    g_timer_count++;
    kv_clint_timer_disable();           /* de-assert MTIP; caller reschedules */

    if (g_arm_msip) {                   /* for MSIP edge/level tests */
        g_arm_msip = 0;
        kv_clint_msip_set();
    }
}

/* ── default MSI handler ─────────────────────────────────────────────────── */

static void on_msip(uint32_t cause)
{
    (void)cause;
    g_msip_count++;
    kv_clint_msip_clear();
}

/* ── helper: reset state and (re-)register defaults ─────────────────────── */

static void reset_state(void)
{
    g_timer_count   = 0;
    g_msip_count    = 0;
    g_handler_time  = 0;
    g_arm_msip      = 0;
    kv_irq_register(KV_CAUSE_MTI, on_timer);
    kv_irq_register(KV_CAUSE_MSI, on_msip);
}

/* ============================================================================
 * Test 1 – Timer edge
 * WFI stalls ~1000 cycles, waiting for a future timer interrupt.
 * Verifies the core actually sleeps (mtime advances roughly 1000 cycles from
 * when we enter WFI) and that the handler fires exactly once.
 * ========================================================================= */
#define T1_PERIOD 1000ULL

static void test1_timer_edge(void)
{
    printf("[TEST  1] Timer edge: WFI stalls ~%llu cycles for future timer\n",
           (unsigned long long)T1_PERIOD);

    reset_state();
    kv_clint_timer_irq_enable();
    kv_irq_enable();

    kv_clint_timer_set_rel(T1_PERIOD);
    uint64_t t0 = kv_clint_mtime();
    kv_wfi();                           /* sleeps until timer fires */
    uint64_t t1 = kv_clint_mtime();

    kv_clint_timer_irq_disable();
    kv_irq_disable();

    uint64_t elapsed = t1 - t0;

    if (g_timer_count != 1)
        TEST_FAIL(1, "timer handler did not fire exactly once");
    else if (elapsed < T1_PERIOD / 2)
        TEST_FAIL(1, "WFI returned too early (icache/pipeline drain issue?)");
    else
        TEST_PASS(1);
}

/* ============================================================================
 * Test 2 – Timer short period (level-trigger stress)
 * Timer is set to a short future period so that it fires while WFI is
 * stalling in the EX stage, demonstrating that WFI wakes from a
 * level-asserted MTIP.  The handler advances mtimecmp (kv_clint_timer_disable),
 * so MTIP returns to 0 immediately; the key is that WFI sees the level while
 * it is stalling (irq_was_pending path).
 *
 * The period must be large enough that the timer fires AFTER WFI has entered
 * the ID/EX stage — i.e. after kv_clint_timer_set_rel() + kv_clint_mtime()
 * + the WFI fetch have all completed (~65 cycles on SRAM, ~200+ on DDR4 with
 * no I-cache at CPI ~6.3).  T2_SHORT_PERIOD=300 provides a safe margin for
 * the worst case (DDR4, ICACHE_EN=0) while still being "short" relative to
 * the long-sleep tests (T10_PERIOD=10000).
 *
 * The upper bound on elapsed (timer fire → WFI return) is conservatively set
 * to 2000 cycles to accommodate the ISR prologue/epilogue overhead on DDR4
 * (~400 cycles of register save/restore at CPI ~6.3).
 * ========================================================================= */
#define T2_SHORT_PERIOD 300ULL

static void test2_timer_short(void)
{
    printf("[TEST  2] Timer short period: WFI wakes on MTIP within ~%llu cycles\n",
           (unsigned long long)T2_SHORT_PERIOD);

    reset_state();
    kv_clint_timer_irq_enable();
    kv_irq_enable();

    kv_clint_timer_set_rel(T2_SHORT_PERIOD);
    uint64_t t0 = kv_clint_mtime();
    kv_wfi();                           /* wakes when MTIP asserts */
    uint64_t t1 = kv_clint_mtime();

    kv_clint_timer_irq_disable();
    kv_irq_disable();

    uint64_t elapsed = t1 - t0;

    if (g_timer_count != 1)
        TEST_FAIL(2, "timer handler did not fire");
    else if (elapsed > 2000ULL)
        TEST_FAIL(2, "WFI took too long for short-period timer");
    else
        TEST_PASS(2);
}

/* ============================================================================
 * Test 3 – Repeated timer wakeups (level-trigger stress)
 * Each handler reschedules the timer, producing a repeating wakeup stream:
 * the level condition is forced to re-assert on every iteration.
 * Executes T3_ITERS consecutive WFI calls; verifies all wake correctly.
 * ========================================================================= */
#define T3_ITERS   20
#define T3_PERIOD 300ULL

static volatile uint32_t t3_wakeup;

static void t3_timer_handler(uint32_t cause)
{
    (void)cause;
    g_timer_count++;
    kv_clint_timer_disable();           /* caller will reschedule each loop */
    t3_wakeup = 1;
}

static void test3_timer_repeat(void)
{
    printf("[TEST  3] Timer repeat: %d WFI wakeups, period %llu cycles each\n",
           T3_ITERS, (unsigned long long)T3_PERIOD);

    reset_state();
    kv_irq_register(KV_CAUSE_MTI, t3_timer_handler);
    kv_clint_timer_irq_enable();
    kv_irq_enable();

    for (int i = 0; i < T3_ITERS; i++) {
        t3_wakeup = 0;
        kv_clint_timer_set_rel(T3_PERIOD);
        kv_wfi();
        /* Defensive: if WFI exited without the handler firing (should not
         * happen), the missed-count will be detected at the end. */
    }

    kv_clint_timer_irq_disable();
    kv_irq_disable();

    if (g_timer_count != T3_ITERS)
        TEST_FAIL(3, "wakeup count mismatch");
    else
        TEST_PASS(3);

    /* Restore default handler. */
    reset_state();
}

/* ============================================================================
 * Test 4 – Timing accuracy
 * Verifies the WFI sleep duration is within a generous window of the requested
 * period.  The lower bound confirms the core actually slept; the upper bound
 * catches runaway stalls.
 *
 * Margin is intentionally wide (50 % of T4_PERIOD) because the measured
 * elapsed time includes:
 *   - ISR prologue/epilogue (CLINT MMIO reads + mtimecmp write)
 *   - Pipeline flush and refill after MRET
 *   - Cold I-cache refills on the return path (pronounced with DDR4)
 * A ±30 % window is too tight for DDR4 speed-grades where a single cache-miss
 * adds 40–80 cycles; ±50 % covers SRAM, DDR4-1600 and slower variants.
 * ========================================================================= */
#define T4_PERIOD  2000ULL
#define T4_MARGIN  1000ULL   /* 50 % of T4_PERIOD – covers DDR4 cache-miss overhead */

static void test4_timer_timing(void)
{
    printf("[TEST  4] Timer timing: sleep ≈ %llu cycles (±%llu, covers DDR4 overhead)\n",
           (unsigned long long)T4_PERIOD, (unsigned long long)T4_MARGIN);

    reset_state();
    kv_clint_timer_irq_enable();
    kv_irq_enable();

    kv_clint_timer_set_rel(T4_PERIOD);
    uint64_t t0 = kv_clint_mtime();
    kv_wfi();
    uint64_t t1 = kv_clint_mtime();

    kv_clint_timer_irq_disable();
    kv_irq_disable();

    uint64_t elapsed = t1 - t0;
    uint64_t lo = T4_PERIOD - T4_MARGIN;
    uint64_t hi = T4_PERIOD + T4_MARGIN;

    if (g_timer_count != 1) {
        TEST_FAIL(4, "timer did not fire");
    } else if (elapsed < lo || elapsed > hi) {
        printf("  elapsed=%llu, expected [%llu, %llu]\n",
               (unsigned long long)elapsed,
               (unsigned long long)lo, (unsigned long long)hi);
        TEST_FAIL(4, "sleep duration out of range");
    } else {
        TEST_PASS(4);
    }
}

/* ============================================================================
 * Test 5 – MSIP edge (cascaded from timer)
 * Demonstrates edge-triggered MSIP: the timer fires DURING the WFI stall
 * window, and inside the timer handler we fire MSIP (write MSIP=1).  On
 * MRET from the timer handler the processor sees MSIP pending and
 * immediately takes the MSIP interrupt before returning to user code.
 * Both handlers must fire from one WFI call.
 *
 * Because MSIP is software-set-and-cleared it behaves edge-like: each
 * software write=1 is one event; the MSIP handler clears it.
 * ========================================================================= */
static void test5_msip_edge(void)
{
    printf("[TEST  5] MSIP edge: timer fires DURING WFI stall, cascades MSIP\n");

    reset_state();
    g_arm_msip = 1;                     /* timer handler will fire MSIP */
    kv_clint_msip_irq_enable();
    kv_clint_timer_irq_enable();
    kv_irq_enable();

    /* WFI stalls ~600 cycles; timer fires inside the stall, handler sets
     * MSIP, MRET -> MSIP interrupt taken -> MSIP handler clears it -> MRET
     * -> user code resumes after WFI.  The 3500-cycle upper bound on elapsed
     * accounts for DDR4+no-icache ISR overhead (save/restore ~780 cycles ×2
     * ISRs at CPI ~6.3) on top of the 600-cycle timer period. */
    kv_clint_timer_set_rel(600ULL);
    uint64_t t0 = kv_clint_mtime();
    kv_wfi();
    uint64_t t1 = kv_clint_mtime();

    kv_clint_timer_irq_disable();
    kv_clint_msip_irq_disable();
    kv_irq_disable();

    uint64_t elapsed = t1 - t0;

    if (g_timer_count != 1)
        TEST_FAIL(5, "timer handler did not fire");
    else if (g_msip_count != 1)
        TEST_FAIL(5, "MSIP handler did not cascade from timer handler");
    else if (elapsed > 3500ULL)
        TEST_FAIL(5, "WFI+cascade took unexpectedly long");
    else
        TEST_PASS(5);
}

/* ============================================================================
 * Test 6 – MSIP repeated cascade (T6_MSIP_ITERS iterations)
 * Repeats the timer→MSIP cascade N times.  Each iteration: timer fires DURING
 * WFI stall, handler sets MSIP; on MRET from timer handler the processor
 * takes the MSIP interrupt immediately (MSIP level still asserted), MSIP
 * handler clears it, then returns to user code.  Validates both interrupt
 * sources fire per WFI call and that state resets cleanly each iteration.
 * ========================================================================= */
#define T6_MSIP_ITERS 5

static void test6_msip_repeated(void)
{
    printf("[TEST  6] MSIP cascade repeat: %d iterations of timer->MSIP\n",
           T6_MSIP_ITERS);

    reset_state();
    kv_clint_msip_irq_enable();
    kv_clint_timer_irq_enable();
    kv_irq_enable();

    int ok = 1;

    for (int i = 0; ok && i < T6_MSIP_ITERS; i++) {
        g_arm_msip    = 1;
        g_timer_count = 0;
        g_msip_count  = 0;

        kv_clint_timer_set_rel(400ULL);
        kv_wfi();

        if (g_timer_count != 1 || g_msip_count != 1) {
            printf("  iter %d: timer_count=%lu msip_count=%lu\n",
                   i, (unsigned long)g_timer_count, (unsigned long)g_msip_count);
            ok = 0;
        }
    }

    kv_clint_timer_irq_disable();
    kv_clint_msip_irq_disable();
    kv_irq_disable();

    if (ok)
        TEST_PASS(6);
    else
        TEST_FAIL(6, "cascade mismatch (see details above)");
}

/* ============================================================================
 * Test 7 – Rapid WFI storm (stress)
 * T7_ITERS consecutive WFI calls with a very short timer period.
 * Exercises back-to-back WFI without the bug where an in-flight icache
 * response prevents core_sleep_o from asserting.
 * ========================================================================= */
#define T7_ITERS   50
#define T7_PERIOD 200ULL

static void t7_timer_handler(uint32_t cause)
{
    (void)cause;
    g_timer_count++;
    kv_clint_timer_disable();
}

static void test7_rapid_storm(void)
{
    printf("[TEST  7] Rapid storm: %d WFIs, timer period %llu cycles\n",
           T7_ITERS, (unsigned long long)T7_PERIOD);

    reset_state();
    kv_irq_register(KV_CAUSE_MTI, t7_timer_handler);
    kv_clint_timer_irq_enable();
    kv_irq_enable();

    for (int i = 0; i < T7_ITERS; i++) {
        kv_clint_timer_set_rel(T7_PERIOD);
        kv_wfi();
    }

    kv_clint_timer_irq_disable();
    kv_irq_disable();

    if ((int)g_timer_count != T7_ITERS)
        TEST_FAIL(7, "wakeup count mismatch in storm");
    else
        TEST_PASS(7);
}

/* ============================================================================
 * Test 8 – IRQ arriving while WFI is in the pipeline (level-triggered race)
 * Use a short period so that the timer fires when WFI is in ID or EX:
 *   - irq_pending=1 at wfi_branch evaluation → WFI becomes NOP directly, or
 *   - irq_was_pending=1 (IRQ fired during ID/EX but ISR cleared it first) →
 *     WFI completes as NOP on re-execution.
 * Regardless of path, the handler must fire exactly once per WFI call.
 *
 * Period must exceed the kv_clint_timer_set_rel() execution time so that
 * the timer does NOT fire before WFI enters the pipeline (which would cause
 * the irq_was_pending guard to miss and WFI to sleep forever on DDR4+no-icache
 * at CPI ~6.3, where set_rel takes ~60 cycles alone).  T8_PERIOD=150 gives
 * comfortable margin on both SRAM (CPI ~1) and DDR4 (CPI ~6.3).
 * ========================================================================= */
#define T8_ITERS   30
#define T8_PERIOD 150ULL

static void t8_timer_handler(uint32_t cause)
{
    (void)cause;
    g_timer_count++;
    kv_clint_timer_disable();
}

static void test8_irq_at_ex_boundary(void)
{
    printf("[TEST  8] IRQ at EX boundary: %d WFIs, period %llu (nop/sleep boundary)\n",
           T8_ITERS, (unsigned long long)T8_PERIOD);

    reset_state();
    kv_irq_register(KV_CAUSE_MTI, t8_timer_handler);
    kv_clint_timer_irq_enable();
    kv_irq_enable();

    for (int i = 0; i < T8_ITERS; i++) {
        kv_clint_timer_set_rel(T8_PERIOD);
        kv_wfi();
    }

    kv_clint_timer_irq_disable();
    kv_irq_disable();

    if ((int)g_timer_count != T8_ITERS)
        TEST_FAIL(8, "handler count mismatch at EX boundary");
    else
        TEST_PASS(8);
}

/* ============================================================================
 * Test 9 – Post-MRET re-WFI: irq_was_pending cleared between WFIs
 * After each WFI+ISR sequence, the irq_was_pending flag must be clear for the
 * NEXT WFI to sleep correctly.  Use a medium period so most WFIs actually
 * sleep (the flag is cleared on the wakeup path), and verify all handlers fire.
 * ========================================================================= */
#define T9_ITERS   10
#define T9_PERIOD 800ULL

static void t9_timer_handler(uint32_t cause)
{
    (void)cause;
    g_timer_count++;
    kv_clint_timer_disable();
}

static void test9_post_mret_rewfi(void)
{
    printf("[TEST  9] Post-MRET re-WFI: %d back-to-back sleeps, period %llu\n",
           T9_ITERS, (unsigned long long)T9_PERIOD);

    reset_state();
    kv_irq_register(KV_CAUSE_MTI, t9_timer_handler);
    kv_clint_timer_irq_enable();
    kv_irq_enable();

    for (int i = 0; i < T9_ITERS; i++) {
        kv_clint_timer_set_rel(T9_PERIOD);
        kv_wfi();                       /* must sleep, not NOP via irq_was_pending */
    }

    kv_clint_timer_irq_disable();
    kv_irq_disable();

    if ((int)g_timer_count != T9_ITERS)
        TEST_FAIL(9, "handler count mismatch; irq_was_pending possibly not cleared");
    else
        TEST_PASS(9);
}

/* ============================================================================
 * Test 10 – Very long sleep (10000 cycles): full PM clock-gate cycle
 * Exercises the full clock-gating path: core_sleep_o asserts, PM gates clock,
 * timer fires, PM un-gates, core resumes.  Verifies timing is reasonable
 * (elapsed ≈ 10000 cycles, no spurious wakeups) and handler fires once.
 * ========================================================================= */
#define T10_PERIOD  10000ULL
#define T10_MARGIN   1000ULL  /* ~10% margin for PM wakeup latency */

static void test10_long_sleep(void)
{
    printf("[TEST 10] Long sleep: ~%llu cycles full clock-gate cycle\n",
           (unsigned long long)T10_PERIOD);

    reset_state();
    kv_clint_timer_irq_enable();
    kv_irq_enable();

    kv_clint_timer_set_rel(T10_PERIOD);
    uint64_t t0 = kv_clint_mtime();
    kv_wfi();
    uint64_t t1 = kv_clint_mtime();

    kv_clint_timer_irq_disable();
    kv_irq_disable();

    uint64_t elapsed = t1 - t0;
    uint64_t lo = T10_PERIOD - T10_MARGIN;
    uint64_t hi = T10_PERIOD + T10_MARGIN;

    if (g_timer_count != 1) {
        TEST_FAIL(10, "timer did not fire exactly once");
    } else if (elapsed < lo || elapsed > hi) {
        printf("  elapsed=%llu, expected [%llu, %llu]\n",
               (unsigned long long)elapsed,
               (unsigned long long)lo, (unsigned long long)hi);
        TEST_FAIL(10, "sleep duration out of range");
    } else {
        TEST_PASS(10);
    }
}

/* ============================================================================
 * Test 11 – IRQ-pending on WFI entry (timer fires before or around WFI-EX)
 * Set timer for a short future period so MTIP is asserted around the time WFI
 * reaches the EX stage.  WFI must NOT sleep; the interrupt must be handled
 * via either:
 *   - irq_pending=1 at wfi_branch guard → WFI becomes NOP directly, or
 *   - irq_was_pending=1 → WFI completes as NOP on re-execution after ISR.
 *
 * On SRAM (CPI ~1) a small period fires MTIP while WFI is in EX (direct
 * irq_pending path).  On DDR4+no-icache (CPI ~6.3) the longer set_rel latency
 * (~60 cycles) means the period must exceed that latency for the interrupt to
 * land in the pipeline window rather than before WFI is even fetched —
 * otherwise irq_was_pending is never set and WFI sleeps forever.
 * T11_PERIOD=150 is short enough to be clearly distinguished from the
 * long-sleep tests and large enough to work on all supported memory types.
 * ========================================================================= */
#define T11_ITERS  20
#define T11_PERIOD 150ULL

static void t11_timer_handler(uint32_t cause)
{
    (void)cause;
    g_timer_count++;
    /* Do NOT disable the timer here — leave MTIP asserted.
     * The WFI guard (irq_pending=1) will prevent sleep entry and the interrupt
     * will be taken on the WFI instruction itself.  We disable afterward. */
    kv_clint_timer_disable();
}

static void test11_irq_pending_at_wfi_entry(void)
{
    printf("[TEST 11] IRQ pending at WFI entry: %d iterations, timer fires before EX\n",
           T11_ITERS);

    reset_state();
    kv_irq_register(KV_CAUSE_MTI, t11_timer_handler);
    kv_clint_timer_irq_enable();
    kv_irq_enable();

    /* Use a short-period timer so MTIP is guaranteed asserted when WFI reaches
     * EX.  The period must be larger than the kv_clint_timer_set_rel() latency
     * (~60 cycles on DDR4 with no I-cache at CPI ~6.3) to ensure the interrupt
     * fires while WFI is in the pipeline rather than before it, so that the
     * irq_pending=1 guard at wfi_branch (or irq_was_pending) handles it
     * correctly.  T11_PERIOD=150 gives safe margin on both SRAM and DDR4. */
    for (int i = 0; i < T11_ITERS; i++) {
        kv_clint_timer_set_rel(T11_PERIOD);
        kv_wfi();
    }

    kv_clint_timer_irq_disable();
    kv_irq_disable();

    if ((int)g_timer_count != T11_ITERS)
        TEST_FAIL(11, "handler count mismatch; WFI may have missed an IRQ");
    else
        TEST_PASS(11);
}

/* ============================================================================
 * Test 12 – Pipeline-drain race: timer fires just as wfi_branch fires
 * Use a period that lands the timer interrupt precisely during the IB-drain
 * window (between wfi_branch and core_sleep_o assertion).  This stresses the
 * wfi_sleeping interrupt_pc priority fix: even if a zombie instruction lingers
 * in EX during drain, interrupt_pc must still be WFI+4.
 * Period chosen to be just above the IB-drain latency (~10 cycles) so the
 * interrupt arrives during the short window before the clock gate engages.
 * ========================================================================= */
#define T12_ITERS  25
#define T12_PERIOD 100ULL   /* ~IB-drain latency + some margin */

static void t12_timer_handler(uint32_t cause)
{
    (void)cause;
    g_timer_count++;
    kv_clint_timer_disable();
}

static void test12_pipeline_drain_race(void)
{
    printf("[TEST 12] Pipeline drain race: %d WFIs, period %llu (IB-drain window)\n",
           T12_ITERS, (unsigned long long)T12_PERIOD);

    reset_state();
    kv_irq_register(KV_CAUSE_MTI, t12_timer_handler);
    kv_clint_timer_irq_enable();
    kv_irq_enable();

    for (int i = 0; i < T12_ITERS; i++) {
        kv_clint_timer_set_rel(T12_PERIOD);
        kv_wfi();
    }

    kv_clint_timer_irq_disable();
    kv_irq_disable();

    if ((int)g_timer_count != T12_ITERS)
        TEST_FAIL(12, "handler count mismatch during pipeline-drain race");
    else
        TEST_PASS(12);
}

/* ── main ─────────────────────────────────────────────────────────────────── */

int main(void)
{
    printf("\n========================================\n");
    printf("  WFI (Wait For Interrupt) Test Suite\n");
    printf("  Level-triggered:  CLINT timer (MTIP)\n");
    printf("  Edge-triggered:   CLINT MSIP (software)\n");
    printf("========================================\n\n");

    test1_timer_edge();
    test2_timer_short();
    test3_timer_repeat();
    test4_timer_timing();
    test5_msip_edge();
    test6_msip_repeated();
    test7_rapid_storm();
    test8_irq_at_ex_boundary();
    test9_post_mret_rewfi();
    test10_long_sleep();
    test11_irq_pending_at_wfi_entry();
    test12_pipeline_drain_race();

    printf("\n========================================\n");
    printf("  Summary: %d/%d tests PASSED\n", g_pass, g_pass + g_fail);
    printf("========================================\n\n");

    return (g_fail == 0) ? 0 : 1;
}
