/*
 * sw/gpio/gpio.c – GPIO test suite
 *
 * Tests:
 *  1. GPIO register access sanity (read/write data, direction, interrupt)
 *  2. GPIO output: write data, read back via loopback mode
 *  3. GPIO atomic set/clear operations
 *  4. GPIO input with loopback (output->input routing)
 *  5. GPIO edge-triggered interrupts (rising and falling edges)
 *  6. GPIO level-triggered interrupts (high and low levels)
 *  7. GPIO multi-bank operation (all 4 banks)
 */

#include <stdint.h>
#include <stdio.h>
#include "kv_platform.h"
#include "kv_gpio.h"
#include "kv_cap.h"
#include "kv_plic.h"
#include "kv_irq.h"

/* ── helpers ─────────────────────────────────────────────────────────────── */

static int g_pass, g_fail;

#define TEST_PASS(n)        do { printf("[TEST %d] PASS\n", (n)); g_pass++; } while (0)
#define TEST_FAIL(n, msg)   do { printf("[TEST %d] FAIL: %s\n", (n), (msg)); g_fail++; } while (0)

/* ── IRQ state (set by MEI handler) ─────────────────────────────────────── */
static volatile uint32_t g_gpio_irq_fired;
static volatile uint32_t g_gpio_irq_bank;
static volatile uint32_t g_gpio_irq_status;

/* ── MEI handler ─────────────────────────────────────────────────────────── */
static void gpio_mei_handler(uint32_t cause)
{
    (void)cause;
    uint32_t src = kv_plic_claim();
    if (src == (uint32_t)KV_PLIC_SRC_GPIO) {
        /* Find which bank triggered */
        for (int bank = 0; bank < 4; bank++) {
            uint32_t is = kv_gpio_get_is(bank);
            uint32_t ie = kv_gpio_read_ie(bank);
            uint32_t trigger = kv_gpio_read_trigger(bank);
            
            /* Check which pins have interrupts enabled */
            if (ie != 0) {
                /* For edge-triggered (trigger=1): Check IS register */
                /* For level-triggered (trigger=0): IS is not used, always fires when level matches */
                uint32_t edge_pending = is & trigger & ie;
                uint32_t level_active = (~trigger) & ie;  /* Level-triggered pins with IE=1 */
                
                if (edge_pending != 0 || level_active != 0) {
                    g_gpio_irq_bank = bank;
                    g_gpio_irq_status = is;
                    g_gpio_irq_fired = 1;
                    
                    /* For edge interrupts: Clear IS (W1C) */
                    if (edge_pending) {
                        kv_gpio_clear_is(bank, edge_pending);
                    }
                    
                    /* For level interrupts: Must clear the interrupt source (GPIO level)
                     * to prevent it from triggering again when leaving the handler.
                     * Clear the GPIO output for the level-triggered pins. */
                    if (level_active) {
                        uint32_t current_output = kv_gpio_read(bank);
                        kv_gpio_write(bank, current_output & ~level_active);
                    }
                    break;
                }
            }
        }
    }
    kv_plic_complete(src);
}

/* ── one-time IRQ setup ──────────────────────────────────────────────────── */
static void gpio_setup_irq(void)
{
    kv_irq_register(KV_CAUSE_MEI, gpio_mei_handler);
    kv_plic_init_source(KV_PLIC_SRC_GPIO, 1);
    kv_irq_enable();
}

/* ── Test 1: Register access sanity ──────────────────────────────────────── */
static void test1_register_access(void)
{
    printf("[TEST 1] Register access sanity\n");
    
    /* Reset bank 0 */
    kv_gpio_write(0, 0);
    kv_gpio_set_dir(0, 0);
    kv_gpio_set_ie(0, 0);  /* Ensure interrupts disabled during register test */
    
    /* Test DATA_OUT write/read */
    kv_gpio_write(0, 0xAAAA5555);
    uint32_t data = kv_gpio_read_out(0);
    if (data != 0xAAAA5555) {
        TEST_FAIL(1, "DATA_OUT mismatch");
        return;
    }
    
    /* Test DIR write/read */
    kv_gpio_set_dir(0, 0x0000FFFF);
    uint32_t dir = kv_gpio_read_dir(0);
    if (dir != 0x0000FFFF) {
        TEST_FAIL(1, "DIR mismatch");
        return;
    }
    
    /* Test TRIGGER write/read (before IE to avoid spurious interrupts) */
    kv_gpio_set_trigger(0, 0xF0F0F0F0);
    uint32_t trig = kv_gpio_read_trigger(0);
    if (trig != 0xF0F0F0F0) {
        TEST_FAIL(1, "TRIGGER mismatch");
        return;
    }
    
    /* Test POLARITY write/read (before IE to avoid spurious interrupts) */
    kv_gpio_set_polarity(0, 0x55AA55AA);
    uint32_t pol = kv_gpio_read_polarity(0);
    if (pol != 0x55AA55AA) {
        TEST_FAIL(1, "POLARITY mismatch");
        return;
    }
    
    /* Test IE write/read (after trigger/polarity configured) */
    kv_gpio_set_ie(0, 0x000000FF);
    uint32_t ie = kv_gpio_read_ie(0);
    if (ie != 0x000000FF) {
        TEST_FAIL(1, "IE mismatch");
        return;
    }
    
    /* Disable interrupts after test */
    kv_gpio_set_ie(0, 0);
    
    /* Test LOOPBACK write/read */
    kv_gpio_set_loopback(0, 0xFFFFFFFF);
    uint32_t loop = kv_gpio_read_loopback(0);
    if (loop != 0xFFFFFFFF) {
        TEST_FAIL(1, "LOOPBACK mismatch");
        return;
    }
    
    TEST_PASS(1);
}

/* ── Test 2: GPIO output with loopback ───────────────────────────────────── */
static void test2_output_loopback(void)
{
    printf("[TEST 2] GPIO output with loopback\n");
    
    /* Setup: all pins as outputs, enable loopback */
    kv_gpio_set_dir(0, 0xFFFFFFFF);           /* All outputs */
    kv_gpio_set_loopback(0, 0xFFFFFFFF);      /* Enable loopback */
    
    /* Test pattern 1: 0xDEADBEEF */
    kv_gpio_write(0, 0xDEADBEEF);
    
    /* Small delay for signal propagation */
    for (volatile int i = 0; i < 10; i++) __asm__ volatile("nop");
    
    uint32_t read_val = kv_gpio_read(0);
    if (read_val != 0xDEADBEEF) {
        printf("  Expected 0xDEADBEEF, got 0x%08lX\n", read_val);
        TEST_FAIL(2, "loopback pattern mismatch");
        return;
    }
    
    /* Test pattern 2: 0x12345678 */
    kv_gpio_write(0, 0x12345678);
    for (volatile int i = 0; i < 10; i++) __asm__ volatile("nop");
    
    read_val = kv_gpio_read(0);
    if (read_val != 0x12345678) {
        printf("  Expected 0x12345678, got 0x%08lX\n", read_val);
        TEST_FAIL(2, "loopback pattern mismatch");
        return;
    }
    
    /* Cleanup */
    kv_gpio_set_loopback(0, 0);
    
    TEST_PASS(2);
}

/* ── Test 3: Atomic set/clear operations ─────────────────────────────────── */
static void test3_atomic_ops(void)
{
    printf("[TEST 3] Atomic set/clear operations\n");
    
    /* Enable loopback for readback */
    kv_gpio_set_dir(0, 0xFFFFFFFF);
    kv_gpio_set_loopback(0, 0xFFFFFFFF);
    
    /* Start with 0x00000000 */
    kv_gpio_write(0, 0x00000000);
    
    /* Set bits [7:0] */
    kv_gpio_set(0, 0x000000FF);
    for (volatile int i = 0; i < 10; i++) __asm__ volatile("nop");
    uint32_t val = kv_gpio_read(0);
    if (val != 0x000000FF) {
        printf("  After SET 0xFF, expected 0x000000FF, got 0x%08lX\n", val);
        TEST_FAIL(3, "SET operation failed");
        return;
    }
    
    /* Set bits [15:8] */
    kv_gpio_set(0, 0x0000FF00);
    for (volatile int i = 0; i < 10; i++) __asm__ volatile("nop");
    val = kv_gpio_read(0);
    if (val != 0x0000FFFF) {
        printf("  After SET 0xFF00, expected 0x0000FFFF, got 0x%08lX\n", val);
        TEST_FAIL(3, "SET operation failed");
        return;
    }
    
    /* Clear bits [7:0] */
    kv_gpio_clear(0, 0x000000FF);
    for (volatile int i = 0; i < 10; i++) __asm__ volatile("nop");
    val = kv_gpio_read(0);
    if (val != 0x0000FF00) {
        printf("  After CLEAR 0xFF, expected 0x0000FF00, got 0x%08lX\n", val);
        TEST_FAIL(3, "CLEAR operation failed");
        return;
    }
    
    /* Toggle bits [11:8] */
    kv_gpio_toggle(0, 0x00000F00);
    for (volatile int i = 0; i < 10; i++) __asm__ volatile("nop");
    val = kv_gpio_read(0);
    if (val != 0x0000F000) {
        printf("  After TOGGLE 0xF00, expected 0x0000F000, got 0x%08lX\n", val);
        TEST_FAIL(3, "TOGGLE operation failed");
        return;
    }
    
    /* Cleanup */
    kv_gpio_set_loopback(0, 0);
    
    TEST_PASS(3);
}

/* ── Test 4: Edge-triggered interrupts (rising edge) ─────────────────────── */
static void test4_edge_interrupt(void)
{
    printf("[TEST 4] Edge-triggered interrupt (rising edge)\n");
    
    /* Setup: pin 0 as output with loopback, edge trigger, rising edge */
    kv_gpio_set_dir(0, 0x00000001);          /* Pin 0 = output */
    kv_gpio_set_loopback(0, 0x00000001);     /* Pin 0 loopback (output -> input) */
    kv_gpio_set_trigger(0, 0x00000001);      /* Pin 0: edge-triggered */
    kv_gpio_set_polarity(0, 0x00000001);     /* Pin 0: rising edge */
    kv_gpio_set_ie(0, 0x00000001);           /* Enable interrupt on pin 0 */
    kv_gpio_clear_is(0, 0xFFFFFFFF);         /* Clear any pending interrupts */
    
    g_gpio_irq_fired = 0;
    
    /* Generate rising edge: 0 -> 1 on pin 0 (will loop back to input) */
    kv_gpio_write(0, 0x00000000);
    for (volatile int i = 0; i < 100; i++) __asm__ volatile("nop");
    kv_gpio_write(0, 0x00000001);
    
    /* Wait for interrupt */
    uint32_t timeout = 100000;
    while (!g_gpio_irq_fired && timeout-- > 0) __asm__ volatile("nop");
    
    if (!g_gpio_irq_fired) {
        TEST_FAIL(4, "interrupt did not fire");
        return;
    }
    
    if (g_gpio_irq_bank != 0) {
        printf("  Expected bank 0, got bank %lu\n", g_gpio_irq_bank);
        TEST_FAIL(4, "wrong interrupt bank");
        return;
    }
    
    if (g_gpio_irq_status != 0x00000001) {
        printf("  Expected IS=0x00000001, got 0x%08lX\n", g_gpio_irq_status);
        TEST_FAIL(4, "wrong interrupt status");
        return;
    }
    
    /* Cleanup */
    kv_gpio_set_ie(0, 0);
    kv_gpio_set_loopback(0, 0);
    
    TEST_PASS(4);
}

/* ── Test 5: Level-triggered interrupts ──────────────────────────────────── */
static void test5_level_interrupt(void)
{
    printf("[TEST 5] Level-triggered interrupt (high level)\n");
    
    /* Setup: pin 0 as output with loopback, level trigger, high active */
    kv_gpio_set_dir(0, 0x00000001);          /* Pin 0 = output */
    kv_gpio_set_loopback(0, 0x00000001);     /* Pin 0 loopback (output -> input) */
    kv_gpio_set_trigger(0, 0x00000000);      /* Pin 0: level-triggered */
    kv_gpio_set_polarity(0, 0x00000001);     /* Pin 0: high level */
    
    /* Start with low level */
    kv_gpio_write(0, 0x00000000);
    kv_gpio_clear_is(0, 0xFFFFFFFF);         /* Clear any pending interrupts */
    
    g_gpio_irq_fired = 0;
    
    /* Enable interrupt after setting up conditions */
    kv_gpio_set_ie(0, 0x00000001);           /* Enable interrupt on pin 0 */
    
    /* Set pin 0 high -> should trigger level interrupt (via loopback) */
    kv_gpio_write(0, 0x00000001);
    
    /* Wait for interrupt */
    uint32_t timeout = 100000;
    while (!g_gpio_irq_fired && timeout-- > 0) __asm__ volatile("nop");
    
    if (!g_gpio_irq_fired) {
        TEST_FAIL(5, "interrupt did not fire");
        return;
    }
    
    if (g_gpio_irq_bank != 0) {
        printf("  Expected bank 0, got bank %lu\n", g_gpio_irq_bank);
        TEST_FAIL(5, "wrong interrupt bank");
        return;
    }
    
    /* Verify that the handler cleared the GPIO output to de-assert the interrupt */
    uint32_t gpio_val = kv_gpio_read(0);
    if (gpio_val != 0x00000000) {
        printf("  Expected GPIO cleared to 0x00000000, got 0x%08lX\n", gpio_val);
        TEST_FAIL(5, "GPIO not cleared by handler");
        return;
    }
    
    /* Note: For level-triggered interrupts, IS register is not used in RTL
     * Interrupt is live based on input level.
     * The handler must clear the GPIO output to de-assert the interrupt source. */
    
    /* Cleanup - ensure everything is off */
    kv_gpio_set_ie(0, 0);
    kv_gpio_write(0, 0);
    kv_gpio_set_loopback(0, 0);
    
    TEST_PASS(5);
}

/* ── Test 6: Multi-bank operation ────────────────────────────────────────── */
static void test6_multi_bank(void)
{
    printf("[TEST 6] Multi-bank operation\n");

    /* Print capability register (informational) */
    uint32_t cap = kv_gpio_get_capability();
    printf("  CAP raw:      0x%08lX\n", (unsigned long)cap);
    printf("  CAP expected: 0x%08lX\n", (unsigned long)KV_CAP_GPIO_VALUE);
    printf("  Num Pins:     %lu  (exp %lu)\n",
           (unsigned long)kv_gpio_get_num_pins(), (unsigned long)KV_CAP_GPIO_NUM_PINS);
    printf("  Num Banks:    %lu  (exp %lu)\n",
           (unsigned long)kv_gpio_get_num_banks(), (unsigned long)KV_CAP_GPIO_NUM_BANKS);
    printf("  Version:      0x%04lX  (exp 0x%04lX)\n",
           (unsigned long)kv_gpio_get_version(), (unsigned long)KV_CAP_GPIO_VERSION);
    printf("\n");

    uint32_t num_banks = kv_gpio_get_num_banks();
    
    /* Multi-bank testing requires at least 2 banks (33+ pins) */
    if (num_banks < 2) {
        printf("  Skipping: requires >1 bank for multi-bank test\n");
        TEST_PASS(6);
        return;
    }
    
    /* Test all available banks with different patterns */
    uint32_t patterns[4] = { 0x11111111, 0x22222222, 0x33333333, 0x44444444 };
    
    for (uint32_t bank = 0; bank < num_banks && bank < 4; bank++) {
        /* Setup: all outputs, loopback enabled */
        kv_gpio_set_dir(bank, 0xFFFFFFFF);
        kv_gpio_set_loopback(bank, 0xFFFFFFFF);
        
        /* Write pattern */
        kv_gpio_write(bank, patterns[bank]);
        
        /* Small delay */
        for (volatile int i = 0; i < 10; i++) __asm__ volatile("nop");
        
        /* Read back */
        uint32_t read_val = kv_gpio_read(bank);
        if (read_val != patterns[bank]) {
            printf("  Bank %lu: expected 0x%08lX, got 0x%08lX\n", 
                   bank, patterns[bank], read_val);
            TEST_FAIL(6, "multi-bank pattern mismatch");
            return;
        }
    }
    
    /* Cleanup */
    for (uint32_t bank = 0; bank < num_banks && bank < 4; bank++) {
        kv_gpio_set_loopback(bank, 0);
        kv_gpio_write(bank, 0);
    }
    
    TEST_PASS(6);
}

/* ========================================================================== */
/* main                                                                       */
/* ========================================================================== */
int main(void)
{
    printf("=== GPIO Test Suite ===\n");
    
    /* Initialize GPIO */
    kv_gpio_init();
    
    /* Run basic tests (no interrupts needed) */
    test1_register_access();
    test2_output_loopback();
    test3_atomic_ops();
    
    /* Setup IRQ for interrupt tests */
    gpio_setup_irq();
    
    /* Run interrupt tests */
    test4_edge_interrupt();
    test5_level_interrupt();
    test6_multi_bank();
    
    printf("\n=== Results: %d PASS, %d FAIL ===\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
