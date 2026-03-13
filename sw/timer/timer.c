// ============================================================================
// File: timer.c
// Project: KV32 RISC-V Processor
// Description: Timer/PWM test suite: counting, dual-compare, PWM, reload, interrupts
//
// Tests: register sanity, basic counting, dual-compare mode, PWM duty
// cycle, COMPARE1/2 interrupts, timer reload, and variable PWM cycles.
// ============================================================================

#include <stdint.h>
#include <stdio.h>
#include "kv_platform.h"
#include "kv_timer.h"
#include "kv_cap.h"
#include "kv_plic.h"
#include "kv_irq.h"

/* ── helpers ─────────────────────────────────────────────────────────────── */

static int g_pass, g_fail;

#define TEST_PASS(n)        do { printf("[TEST %d] PASS\n", (n)); g_pass++; } while (0)
#define TEST_FAIL(n, msg)   do { printf("[TEST %d] FAIL: %s\n", (n), (msg)); g_fail++; } while (0)

/* ── IRQ state (set by MEI handler) ─────────────────────────────────────── */
static volatile uint32_t g_timer_irq_fired;
static volatile uint32_t g_timer_irq_status;
static volatile uint32_t g_timer_irq_count;

/* ── MEI handler ─────────────────────────────────────────────────────────── */
static void timer_mei_handler(uint32_t cause)
{
    (void)cause;
    uint32_t src = kv_plic_claim();
    if (src == (uint32_t)KV_PLIC_SRC_TIMER0) {
        uint32_t status = kv_timer_get_int_status();
        g_timer_irq_status = status;
        g_timer_irq_fired = 1;
        g_timer_irq_count++;
        /* Clear interrupt status (W1C) */
        kv_timer_clear_int(status);
    }
    kv_plic_complete(src);
}

/* ── one-time IRQ setup ──────────────────────────────────────────────────── */
static void timer_setup_irq(void)
{
    kv_irq_register(KV_CAUSE_MEI, timer_mei_handler);
    kv_plic_init_source(KV_PLIC_SRC_TIMER0, 1);
    kv_irq_enable();
}

/* ── Test 1: Register access sanity ──────────────────────────────────────── */
static void test1_register_access(void)
{
    printf("[TEST 1] Register access sanity\n");

    /* Test COUNT register */
    KV_TIMER_COUNT(0) = 0x12345678;
    uint32_t count = KV_TIMER_COUNT(0);
    if (count != 0x12345678) {
        TEST_FAIL(1, "COUNT mismatch");
        return;
    }

    /* Test COMPARE1 register */
    KV_TIMER_COMPARE1(0) = 0xAAAAAAAA;
    uint32_t cmp1 = KV_TIMER_COMPARE1(0);
    if (cmp1 != 0xAAAAAAAA) {
        TEST_FAIL(1, "COMPARE1 mismatch");
        return;
    }

    /* Test COMPARE2 register */
    KV_TIMER_COMPARE2(0) = 0x55555555;
    uint32_t cmp2 = KV_TIMER_COMPARE2(0);
    if (cmp2 != 0x55555555) {
        TEST_FAIL(1, "COMPARE2 mismatch");
        return;
    }

    /* Test CTRL register */
    KV_TIMER_CTRL(0) = 0x00010005;
    uint32_t ctrl = KV_TIMER_CTRL(0);
    if (ctrl != 0x00010005) {
        TEST_FAIL(1, "CTRL mismatch");
        return;
    }

    /* Stop timer and clear */
    KV_TIMER_CTRL(0) = 0;

    TEST_PASS(1);
}

/* ── Test 2: Basic counting (single compare) ─────────────────────────────── */
static void test2_basic_counting(void)
{
    printf("[TEST 2] Basic counting (single compare)\n");

    /* Reset timer 0 */
    kv_timer_stop(0);
    KV_TIMER_COUNT(0) = 0;

    /* Set COMPARE1 = 100 (should match after 100 ticks) */
    kv_timer_start(0, 10000, 0);  /* period=10000, prescale=0 */

    /* Wait for count to reach 100 */
    uint32_t timeout = 100000;
    while (kv_timer_get_count(0) < 100 && timeout-- > 0) {
        __asm__ volatile("nop");
    }

    if (timeout == 0) {
        TEST_FAIL(2, "timer did not count");
        return;
    }

    uint32_t count = kv_timer_get_count(0);
    if (count < 100) {
        printf("  Expected count >= 100, got %lu\n", count);
        TEST_FAIL(2, "count too low");
        return;
    }

    kv_timer_stop(0);
    TEST_PASS(2);
}

/* ── Test 3: Dual-compare mode ───────────────────────────────────────────── */
static void test3_dual_compare(void)
{
    printf("[TEST 3] Dual-compare mode\n");

    /* Reset timer 0 */
    kv_timer_stop(0);
    KV_TIMER_COUNT(0) = 0;

    /* Set COMPARE1 = 50, COMPARE2 = 100 */
    kv_timer_start_dual(0, 50, 100, 0, 0);  /* compare1=50, compare2=100, prescale=0, int_en=0 */

    /* Wait for count to reach 50 */
    uint32_t timeout = 100000;
    while (kv_timer_get_count(0) < 50 && timeout-- > 0) {
        __asm__ volatile("nop");
    }

    if (timeout == 0) {
        TEST_FAIL(3, "timer did not reach COMPARE1");
        return;
    }

    /* Wait a bit more, should reload at COMPARE2 (100) */
    timeout = 100000;
    uint32_t count_at_50 = kv_timer_get_count(0);
    while (kv_timer_get_count(0) >= count_at_50 && timeout-- > 0) {
        __asm__ volatile("nop");
    }

    if (timeout == 0) {
        TEST_FAIL(3, "timer did not reload at COMPARE2");
        return;
    }

    /* After reload, count should be small again */
    uint32_t count_after_reload = kv_timer_get_count(0);
    if (count_after_reload > 50) {
        printf("  After reload, expected count < 50, got %lu\n", count_after_reload);
        TEST_FAIL(3, "reload failed");
        return;
    }

    kv_timer_stop(0);
    TEST_PASS(3);
}

/* ── Test 4: PWM mode with duty cycle ────────────────────────────────────── */
static void test4_pwm_mode(void)
{
    printf("[TEST 4] PWM mode with duty cycle\n");

    /* Start PWM: frequency = 1000 Hz, duty = 50% (assuming CPU freq = 100 MHz) */
    /* For simplicity, use small period = 100 ticks, duty = 50 ticks */
    kv_timer_pwm_start(0, 100, 50, 0);  /* period=100, duty=50, prescale=0 */

    /* Let PWM run for a bit */
    for (volatile int i = 0; i < 1000; i++) {
        __asm__ volatile("nop");
    }

    /* Verify timer is running */
    uint32_t count = kv_timer_get_count(0);
    if (count == 0) {
        TEST_FAIL(4, "PWM timer not running");
        return;
    }

    /* Change duty cycle to 75% */
    kv_timer_pwm_set_duty(0, 100, 75);

    /* Let it run more */
    for (volatile int i = 0; i < 1000; i++) {
        __asm__ volatile("nop");
    }

    /* Stop PWM */
    kv_timer_pwm_stop(0);

    TEST_PASS(4);
}

/* ── Test 5: Timer interrupt (COMPARE1) ──────────────────────────────────── */
static void test5_timer_interrupt(void)
{
    printf("[TEST 5] Timer interrupt (COMPARE1)\n");

    /* Reset timer and IRQ state */
    kv_timer_stop(0);
    KV_TIMER_COUNT(0) = 0;
    g_timer_irq_fired = 0;
    g_timer_irq_count = 0;
    kv_timer_clear_int(0xF);  /* Clear all pending interrupts */

    /* Enable timer 0 interrupt */
    KV_TIMER_INT_ENABLE = 0x1;

    /* Start timer with COMPARE1 = 200, interrupt enabled */
    kv_timer_start_dual(0, 200, 0xFFFFFFFF, 0, 1);  /* compare1=200, compare2=max, prescale=0, int_en=1 */

    /* Wait for interrupt */
    uint32_t timeout = 100000;
    while (!g_timer_irq_fired && timeout-- > 0) {
        __asm__ volatile("nop");
    }

    if (!g_timer_irq_fired) {
        TEST_FAIL(5, "interrupt did not fire");
        return;
    }

    if ((g_timer_irq_status & 0x1) == 0) {
        printf("  Expected INT_STATUS bit 0 set, got 0x%08lX\n", g_timer_irq_status);
        TEST_FAIL(5, "wrong interrupt status");
        return;
    }

    /* Cleanup */
    kv_timer_stop(0);
    KV_TIMER_INT_ENABLE = 0;

    TEST_PASS(5);
}

/* ── Test 6: Dual-compare interrupts ─────────────────────────────────────── */
static void test6_dual_interrupt(void)
{
    printf("[TEST 6] Dual-compare interrupts\n");

    /* Reset timer and IRQ state */
    kv_timer_stop(0);
    KV_TIMER_COUNT(0) = 0;
    g_timer_irq_fired = 0;
    g_timer_irq_count = 0;
    kv_timer_clear_int(0xF);

    /* Enable timer 0 interrupt */
    KV_TIMER_INT_ENABLE = 0x1;

    /* Start timer: COMPARE1 = 100, COMPARE2 = 200, both should trigger IRQ */
    kv_timer_start_dual(0, 2000, 4000, 0, 1);  /* compare1=2000, compare2=4000, prescale=0, int_en=1 */

    /* Wait for first interrupt (at COMPARE1 = 2000) */
    uint32_t timeout = 1000000;
    while (!g_timer_irq_fired && timeout-- > 0) {
        __asm__ volatile("nop");
    }

    if (!g_timer_irq_fired) {
        TEST_FAIL(6, "first interrupt did not fire");
        return;
    }

    /* Wait for second interrupt (at COMPARE2 = 4000) */
    g_timer_irq_fired = 0;
    timeout = 1000000;
    while (!g_timer_irq_fired && timeout-- > 0) {
        __asm__ volatile("nop");
    }

    if (!g_timer_irq_fired) {
        TEST_FAIL(6, "second interrupt did not fire");
        return;
    }

    /* Should have at least 2 interrupts total */
    if (g_timer_irq_count < 2) {
        printf("  Expected at least 2 interrupts, got %lu\n", g_timer_irq_count);
        TEST_FAIL(6, "insufficient interrupt count");
        return;
    }

    /* Cleanup */
    kv_timer_stop(0);
    KV_TIMER_INT_ENABLE = 0;

    TEST_PASS(6);
}

/* ── Test 7: Timer reload on COMPARE2 ────────────────────────────────────── */
static void test7_timer_reload(void)
{
    printf("[TEST 7] Timer reload on COMPARE2\n");

    /* Reset timer */
    kv_timer_stop(0);
    KV_TIMER_COUNT(0) = 0;

    /* Start timer: COMPARE2 = 150 (reload point) */
    kv_timer_start_dual(0, 75, 150, 0, 0);  /* compare1=75, compare2=150, prescale=0, int_en=0 */

    /* Wait for counter to reach 150 and reload */
    uint32_t timeout = 100000;
    while (kv_timer_get_count(0) < 145 && timeout-- > 0) {
        __asm__ volatile("nop");
    }

    if (timeout == 0) {
        TEST_FAIL(7, "timer did not count");
        return;
    }

    /* Wait a bit more for reload */
    for (volatile int i = 0; i < 100; i++) {
        __asm__ volatile("nop");
    }

    /* After reload, count must be less than COMPARE2 (150).
     * The hardware guarantees counter can never reach COMPARE2 while running —
     * it reloads to 0 on the compare match tick.  Checking >= 150 is correct
     * regardless of CPU speed (single-port vs dual-port BRAM arbitration). */
    uint32_t count_after_reload = kv_timer_get_count(0);
    if (count_after_reload >= 150) {
        printf("  After reload, expected count < 150, got %lu\n", count_after_reload);
        TEST_FAIL(7, "reload did not occur");
        return;
    }

    kv_timer_stop(0);
    TEST_PASS(7);
}

/* ── Test 8: PWM with different duty cycles ──────────────────────────────── */
static void test8_pwm_duty_cycles(void)
{
    printf("[TEST 8] PWM with different duty cycles\n");

    /* Test 25% duty cycle */
    kv_timer_pwm_start(0, 100, 25, 0);
    for (volatile int i = 0; i < 500; i++) __asm__ volatile("nop");

    uint32_t count = kv_timer_get_count(0);
    if (count == 0) {
        TEST_FAIL(8, "PWM not running (25% duty)");
        return;
    }

    /* Test 75% duty cycle */
    kv_timer_pwm_set_duty(0, 100, 75);
    for (volatile int i = 0; i < 500; i++) __asm__ volatile("nop");

    count = kv_timer_get_count(0);
    if (count == 0) {
        TEST_FAIL(8, "PWM not running (75% duty)");
        return;
    }

    /* Test 0% duty cycle (always low) */
    kv_timer_pwm_set_duty(0, 100, 0);
    for (volatile int i = 0; i < 500; i++) __asm__ volatile("nop");

    /* Test 100% duty cycle (always high) */
    kv_timer_pwm_set_duty(0, 100, 100);
    for (volatile int i = 0; i < 500; i++) __asm__ volatile("nop");

    kv_timer_pwm_stop(0);
    TEST_PASS(8);
}

/* ========================================================================== */
/* main                                                                       */
/* ========================================================================== */
int main(void)
{
    printf("=== Timer/PWM Test Suite ===\n");

    /* Initialize Timer */
    kv_timer_init();

    /* TEST 0: Capability register (informational) */
    printf("\n[TEST 0] Capability Register\n");
    uint32_t cap = kv_timer_get_capability();
    printf("  CAP raw:        0x%08lX\n", (unsigned long)cap);
    printf("  CAP expected:   0x%08lX\n", (unsigned long)KV_CAP_TIMER_VALUE);
    printf("  Num Channels:   %lu  (exp %lu)\n",
           (unsigned long)kv_timer_get_num_channels(), (unsigned long)KV_CAP_TIMER_NUM_CHANNELS);
    printf("  Counter Width:  %lu  (exp %lu)\n",
           (unsigned long)kv_timer_get_counter_width(), (unsigned long)KV_CAP_TIMER_COUNTER_WIDTH);
    printf("  Version:        0x%04lX  (exp 0x%04lX)\n",
           (unsigned long)kv_timer_get_version(), (unsigned long)KV_CAP_TIMER_VERSION);
    printf("\n");

    /* Setup IRQ for interrupt tests */
    timer_setup_irq();

    test1_register_access();
    test2_basic_counting();
    test3_dual_compare();
    test4_pwm_mode();
    test5_timer_interrupt();
    test6_dual_interrupt();
    test7_timer_reload();
    test8_pwm_duty_cycles();

    printf("\n=== Results: %d PASS, %d FAIL ===\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
