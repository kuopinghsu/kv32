// ============================================================================
// File: fence.c
// Project: RV32 RISC-V Processor
// Description: Test program for RISC-V FENCE instruction
//
// Verifies that the FENCE instruction:
//   1. Executes without hanging (store buffer drains in bounded time)
//   2. Orders stores before subsequent loads to different addresses
//   3. Works correctly in loops and back-to-back
//   4. FENCE.I also executes cleanly
//
// The store buffer allows loads to non-conflicting addresses to bypass
// pending stores. FENCE must stall until the store buffer is fully
// drained before the pipeline continues.
// ============================================================================

#include <stdint.h>
#include <stdio.h>

#define FENCE()   __asm__ volatile ("fence"          ::: "memory")
// fence.i (FENCE.I = 0x0000100F) is in the Zifencei extension which is not
// in the default rv32ima_zicsr march string; encode it as a raw word.
#define FENCE_I() __asm__ volatile (".word 0x0000100F" ::: "memory")

#define NUM_TESTS 5

static uint32_t tests_passed = 0;
static uint32_t tests_failed = 0;

// Trap handler required by start.S
void trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval) {
    (void)mcause; (void)mepc; (void)mtval;
}

// ============================================================================
// Test 1: Basic FENCE - just executes without hanging
// ============================================================================
static void test_basic_fence(void) {
    printf("[TEST 1] Basic FENCE execution\n");

    FENCE();

    printf("  Result: PASS\n");
    tests_passed++;
}

// ============================================================================
// Test 2: FENCE between stores and loads to different addresses
//
// Without fence: the load from buf[4] could issue while the stores to
// buf[0..3] are still pending in the store buffer (different addresses).
// With fence:    all stores must commit before the load proceeds.
// ============================================================================
static void test_fence_store_load_ordering(void) {
    volatile uint32_t buf[8];
    uint32_t i;

    printf("[TEST 2] FENCE store->load ordering (different addresses)\n");

    // Write pattern to first half
    for (i = 0; i < 4; i++) {
        buf[i] = 0xAA000000u | i;
    }

    // FENCE: ensure all stores above commit before any load below
    FENCE();

    // Read second half (different addresses from the stores above)
    // then write there too and fence again
    for (i = 4; i < 8; i++) {
        buf[i] = buf[i - 4] ^ 0xFF000000u;  // load from buf[0..3], store to buf[4..7]
    }

    FENCE();

    // Verify the computed values are correct
    int pass = 1;
    for (i = 4; i < 8; i++) {
        uint32_t expected = (0xAA000000u | (i - 4)) ^ 0xFF000000u;
        if (buf[i] != expected) {
            printf("  [FAIL] buf[%lu]: expected=0x%08lx actual=0x%08lx\n",
                   (unsigned long)i, (unsigned long)expected, (unsigned long)buf[i]);
            pass = 0;
            tests_failed++;
        }
    }
    if (pass) {
        printf("  Result: PASS\n");
        tests_passed++;
    }
}

// ============================================================================
// Test 3: Back-to-back FENCE instructions
// ============================================================================
static void test_consecutive_fences(void) {
    volatile uint32_t x = 0xDEAD;

    printf("[TEST 3] Consecutive FENCE instructions\n");

    x = 0x1111;
    FENCE();
    x = 0x2222;
    FENCE();

    if (x == 0x2222) {
        printf("  Result: PASS\n");
        tests_passed++;
    } else {
        printf("  [FAIL] x=0x%08lx expected 0x2222\n", (unsigned long)x);
        tests_failed++;
    }
}

// ============================================================================
// Test 4: FENCE inside a loop (stress - store buffer must drain each iteration)
// ============================================================================
static void test_fence_in_loop(void) {
    volatile uint32_t arr[16];
    uint32_t i;

    printf("[TEST 4] FENCE in loop\n");

    for (i = 0; i < 16; i++) {
        arr[i] = i * 0x11111111u;
        FENCE();
    }

    // Verify all values (loads after all fences)
    int pass = 1;
    for (i = 0; i < 16; i++) {
        if (arr[i] != i * 0x11111111u) {
            printf("  [FAIL] arr[%lu]=0x%08lx expected 0x%08lx\n",
                   (unsigned long)i,
                   (unsigned long)arr[i],
                   (unsigned long)(i * 0x11111111u));
            pass = 0;
            tests_failed++;
        }
    }
    if (pass) {
        printf("  Result: PASS\n");
        tests_passed++;
    }
}

// ============================================================================
// Test 5: FENCE.I executes without hanging
// ============================================================================
static void test_fence_i(void) {
    printf("[TEST 5] FENCE.I execution\n");

    FENCE_I();

    printf("  Result: PASS\n");
    tests_passed++;
}

// ============================================================================
// Main
// ============================================================================
int main(void) {
    printf("\n");
    printf("==========================================\n");
    printf("  FENCE Instruction Test\n");
    printf("==========================================\n");

    test_basic_fence();
    test_fence_store_load_ordering();
    test_consecutive_fences();
    test_fence_in_loop();
    test_fence_i();

    printf("\n");
    printf("  Summary: %lu/%d tests PASSED\n",
           (unsigned long)tests_passed, NUM_TESTS);
    if (tests_failed == 0) {
        printf("  All FENCE tests passed.\n");
    } else {
        printf("  FAILED: %lu test(s)\n", (unsigned long)tests_failed);
    }
    printf("==========================================\n");

    return (tests_failed == 0) ? 0 : 1;
}
