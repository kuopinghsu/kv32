// ============================================================================
// File: wdt.c
// Project: KV32 RISC-V Processor
// Description: Hardware Watchdog Timer (WDT) test suite.
//
// Tests register access, countdown behaviour, kick/reload, stop, and IRQ
// mode.  A strong user_hook() override disables the default heartbeat so
// each test can manage the WDT from a clean, stopped state.
//
// Tests:
//   1  CAP register         : read, verify expected value (0x00010020)
//   2  Register access      : CTRL and LOAD write / read-back
//   3  COUNT decrements     : EN=1 → COUNT is decreasing
//   4  KICK reloads COUNT   : mid-run kick → COUNT snaps back to LOAD
//   5  Stop halts countdown : kv_wdt_stop() → COUNT freezes
//   6  IRQ mode expiry      : INTR_EN=1 → PLIC MEI fires; STATUS[0] set
//   7  STATUS W1C           : write 1 to STATUS clears WDT_INT
//   8  Re-arm after expiry  : KICK after expiry re-starts countdown (EN stays)
// ============================================================================

#include <stdint.h>
#include <stdio.h>
#include "kv_platform.h"
#include "kv_wdt.h"
#include "kv_plic.h"
#include "kv_irq.h"

/* ── Disable the default heartbeat; tests control the WDT themselves ─────── */
void user_hook(void) { }

/* ── Test accounting ─────────────────────────────────────────────────────── */
static int g_pass, g_fail;

#define TEST_PASS(n)        do { printf("[TEST %d] PASS\n", (n)); g_pass++; } while (0)
#define TEST_FAIL(n, msg)   do { printf("[TEST %d] FAIL: %s\n", (n), (msg)); g_fail++; } while (0)

/* ── IRQ state ───────────────────────────────────────────────────────────── */
static volatile uint32_t g_wdt_irq_count;

/* ── MEI handler for WDT PLIC source ────────────────────────────────────── */
static void wdt_mei_handler(uint32_t cause)
{
    (void)cause;
    uint32_t src = kv_plic_claim();
    if (src == (uint32_t)KV_PLIC_SRC_WDT) {
        g_wdt_irq_count++;
        kv_wdt_clear_int();  /* W1C STATUS[0] */
    }
    kv_plic_complete(src);
}

/* ── Helper: put WDT in a known stopped state ────────────────────────────── */
static void wdt_reset_state(void)
{
    kv_wdt_stop();
    kv_wdt_clear_int();
    g_wdt_irq_count = 0;
}

/* ── Test 1: CAP register ────────────────────────────────────────────────── */
static void test1_cap(void)
{
    printf("[TEST 1] CAP register value\n");

    uint32_t cap = KV_REG32(KV_WDT_BASE, KV_WDT_CAP_OFF);
    if (cap != 0x00010020u) {
        TEST_FAIL(1, "CAP register mismatch");
        return;
    }
    TEST_PASS(1);
}

/* ── Test 2: Register access (CTRL / LOAD) ───────────────────────────────── */
static void test2_register_access(void)
{
    printf("[TEST 2] Register access (CTRL, LOAD)\n");
    wdt_reset_state();

    /* LOAD can be written and read back */
    KV_REG32(KV_WDT_BASE, KV_WDT_LOAD_OFF) = 0xDEADBEEFu;
    uint32_t load = KV_REG32(KV_WDT_BASE, KV_WDT_LOAD_OFF);
    if (load != 0xDEADBEEFu) {
        TEST_FAIL(2, "LOAD read-back mismatch");
        return;
    }

    /* CTRL only exposes bits [1:0] */
    KV_REG32(KV_WDT_BASE, KV_WDT_CTRL_OFF) = 0xFFFFFFFFu;
    uint32_t ctrl = KV_REG32(KV_WDT_BASE, KV_WDT_CTRL_OFF);
    if (ctrl != 0x3u) {
        TEST_FAIL(2, "CTRL upper bits not masked");
        return;
    }

    /* Clean up: stop WDT */
    KV_REG32(KV_WDT_BASE, KV_WDT_CTRL_OFF) = 0u;

    TEST_PASS(2);
}

/* ── Test 3: COUNT decrements when EN=1 ─────────────────────────────────── */
static void test3_count_decrements(void)
{
    printf("[TEST 3] COUNT decrements when enabled\n");
    wdt_reset_state();

    /* Start with a large LOAD so we can poll COUNT without it expiring */
    kv_wdt_start(100000u, 1);

    uint32_t c0 = KV_REG32(KV_WDT_BASE, KV_WDT_COUNT_OFF);

    /* Burn a few cycles */
    for (volatile int i = 0; i < 200; i++) {
        __asm__ volatile("nop");
    }

    uint32_t c1 = KV_REG32(KV_WDT_BASE, KV_WDT_COUNT_OFF);
    kv_wdt_stop();

    if (c1 >= c0) {
        TEST_FAIL(3, "COUNT did not decrease");
        return;
    }
    TEST_PASS(3);
}

/* ── Test 4: KICK reloads COUNT from LOAD ───────────────────────────────── */
static void test4_kick_reloads(void)
{
    printf("[TEST 4] KICK reloads COUNT from LOAD\n");
    wdt_reset_state();

    kv_wdt_start(50000u, 1);

    /* Let it count down a bit */
    for (volatile int i = 0; i < 500; i++) {
        __asm__ volatile("nop");
    }

    uint32_t before_kick = KV_REG32(KV_WDT_BASE, KV_WDT_COUNT_OFF);
    kv_wdt_kick();
    uint32_t after_kick = KV_REG32(KV_WDT_BASE, KV_WDT_COUNT_OFF);
    kv_wdt_stop();

    if (before_kick >= 50000u) {
        TEST_FAIL(4, "COUNT never decreased before kick");
        return;
    }
    /* after_kick should be close to LOAD=50000; allow a few ticks between
     * the KICK write and the COUNT read */
    if (after_kick <= before_kick) {
        TEST_FAIL(4, "COUNT not reloaded from LOAD after kick");
        return;
    }
    TEST_PASS(4);
}

/* ── Test 5: Stop halts countdown ───────────────────────────────────────── */
static void test5_stop(void)
{
    printf("[TEST 5] Stop halts countdown\n");
    wdt_reset_state();

    kv_wdt_start(100000u, 1);

    /* Let it tick for a moment */
    for (volatile int i = 0; i < 100; i++) {
        __asm__ volatile("nop");
    }

    kv_wdt_stop();

    uint32_t c0 = KV_REG32(KV_WDT_BASE, KV_WDT_COUNT_OFF);

    /* Further delay: COUNT should not change */
    for (volatile int i = 0; i < 200; i++) {
        __asm__ volatile("nop");
    }

    uint32_t c1 = KV_REG32(KV_WDT_BASE, KV_WDT_COUNT_OFF);

    if (c1 != c0) {
        TEST_FAIL(5, "COUNT changed after stop");
        return;
    }
    TEST_PASS(5);
}

/* ── Test 6: IRQ mode expiry ────────────────────────────────────────────── */
static void test6_irq_mode(void)
{
    printf("[TEST 6] IRQ mode expiry (INTR_EN=1)\n");
    wdt_reset_state();

    /* Set up MEI handler for WDT PLIC source */
    kv_irq_register(KV_CAUSE_MEI, wdt_mei_handler);
    kv_plic_init_source(KV_PLIC_SRC_WDT, 1);
    kv_irq_enable();

    /* Start WDT with a short LOAD so it expires quickly */
    kv_wdt_start(600u, 1);

    /* Busy-wait for the IRQ handler to fire (up to a generous timeout) */
    uint32_t timeout = 200000u;
    while (g_wdt_irq_count == 0 && --timeout > 0) {
        __asm__ volatile("nop");
    }

    kv_wdt_stop();
    kv_irq_disable();
    kv_plic_init_source(KV_PLIC_SRC_WDT, 0);  /* disable PLIC source */

    if (timeout == 0) {
        TEST_FAIL(6, "WDT IRQ never fired");
        return;
    }
    if (g_wdt_irq_count < 1) {
        TEST_FAIL(6, "handler did not record IRQ");
        return;
    }
    TEST_PASS(6);
}

/* ── Test 7: STATUS W1C ─────────────────────────────────────────────────── */
static void test7_status_w1c(void)
{
    printf("[TEST 7] STATUS W1C clears WDT_INT\n");
    wdt_reset_state();

    /* Start WDT, let it expire */
    kv_wdt_start(300u, 1);

    /* Poll STATUS until WDT_INT is set (no PLIC needed) */
    uint32_t timeout = 100000u;
    while (!(KV_REG32(KV_WDT_BASE, KV_WDT_STATUS_OFF) & 1u) && --timeout > 0) {
        __asm__ volatile("nop");
    }

    if (timeout == 0) {
        kv_wdt_stop();
        TEST_FAIL(7, "WDT did not expire (STATUS never set)");
        return;
    }

    /* STATUS[0] should be 1 now */
    if (!(KV_REG32(KV_WDT_BASE, KV_WDT_STATUS_OFF) & 1u)) {
        kv_wdt_stop();
        TEST_FAIL(7, "STATUS[0] not set after expiry");
        return;
    }

    /* W1C: write 1 to clear */
    kv_wdt_clear_int();

    uint32_t status_after = KV_REG32(KV_WDT_BASE, KV_WDT_STATUS_OFF);
    kv_wdt_stop();

    if (status_after & 1u) {
        TEST_FAIL(7, "STATUS[0] not cleared by W1C");
        return;
    }
    TEST_PASS(7);
}

/* ── Test 8: Re-arm after IRQ expiry (EN stays set) ─────────────────────── */
static void test8_rearm(void)
{
    printf("[TEST 8] Re-arm via KICK after IRQ expiry\n");
    wdt_reset_state();

    /* Start WDT and let it expire (no PLIC handler needed; poll STATUS) */
    kv_wdt_start(300u, 1);

    uint32_t timeout = 100000u;
    while (!(KV_REG32(KV_WDT_BASE, KV_WDT_STATUS_OFF) & 1u) && --timeout > 0) {
        __asm__ volatile("nop");
    }

    if (timeout == 0) {
        kv_wdt_stop();
        TEST_FAIL(8, "WDT did not expire");
        return;
    }

    /* After expiry: EN should still be 1 (INTR_EN=1 mode; only INTR_EN=0 clears EN) */
    uint32_t ctrl_after_expiry = KV_REG32(KV_WDT_BASE, KV_WDT_CTRL_OFF);
    if (!(ctrl_after_expiry & 1u)) {
        kv_wdt_stop();
        TEST_FAIL(8, "EN was cleared after IRQ-mode expiry (expected EN=1)");
        return;
    }

    /* COUNT should be latched at 0 */
    uint32_t count_at_expiry = KV_REG32(KV_WDT_BASE, KV_WDT_COUNT_OFF);
    if (count_at_expiry != 0u) {
        kv_wdt_stop();
        TEST_FAIL(8, "COUNT not latched at 0 after expiry");
        return;
    }

    /* KICK reloads COUNT from LOAD (300); allow a few ticks before the read */
    kv_wdt_kick();
    uint32_t count_after_kick = KV_REG32(KV_WDT_BASE, KV_WDT_COUNT_OFF);
    if (count_after_kick < 250u || count_after_kick > 300u) {
        kv_wdt_stop();
        TEST_FAIL(8, "COUNT not reloaded by KICK after expiry");
        return;
    }

    /* Clear STATUS so we can detect a second expiry */
    kv_wdt_clear_int();

    /* Let WDT expire again (proves countdown resumed after kick) */
    timeout = 100000u;
    while (!(KV_REG32(KV_WDT_BASE, KV_WDT_STATUS_OFF) & 1u) && --timeout > 0) {
        __asm__ volatile("nop");
    }

    kv_wdt_stop();

    if (timeout == 0) {
        TEST_FAIL(8, "WDT did not expire again after re-arm");
        return;
    }
    TEST_PASS(8);
}

/* ── main ────────────────────────────────────────────────────────────────── */
int main(void)
{
    printf("WDT Test Suite\n");
    printf("==============\n");

    test1_cap();
    test2_register_access();
    test3_count_decrements();
    test4_kick_reloads();
    test5_stop();
    test6_irq_mode();
    test7_status_w1c();
    test8_rearm();

    printf("\nResults: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
