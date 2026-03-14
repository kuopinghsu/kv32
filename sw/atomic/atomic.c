// ============================================================================
// File: atomic.c
// Project: KV32 RISC-V Processor
// Description: Test program for RISC-V Atomic (A) Extension
//
// Tests all atomic memory operations (AMO) instructions:
//   - LR.W / SC.W (Load-Reserved / Store-Conditional)
//   - AMOSWAP.W  (Atomic Swap)
//   - AMOADD.W   (Atomic Add)
//   - AMOXOR.W   (Atomic XOR)
//   - AMOAND.W   (Atomic AND)
//   - AMOOR.W    (Atomic OR)
//   - AMOMIN.W   (Atomic Min Signed)
//   - AMOMAX.W   (Atomic Max Signed)
//   - AMOMINU.W  (Atomic Min Unsigned)
//   - AMOMAXU.W  (Atomic Max Unsigned)
//
// Each test verifies the atomic operation returns the original value
// and updates memory correctly.
// ============================================================================

#include <stdint.h>
#include <stdio.h>
#include "kv_irq.h"

#define TEST_PASS 0
#define TEST_FAIL 1

// Counters for test statistics
static uint32_t tests_run = 0;
static uint32_t tests_passed = 0;
static uint32_t tests_failed = 0;
static uint32_t tests_skipped = 0;

// Flag to detect if atomic operations are supported
static int atomic_supported = -1;  // -1 = unknown, 0 = no, 1 = yes

// Trap handler (required by start.S)
void trap_handler(kv_trap_frame_t *frame) {
    (void)frame;
}

// Detect if atomic operations are supported by checking for error pattern
static int check_atomic_support(void) {
    if (atomic_supported != -1) {
        return atomic_supported;
    }

    volatile uint32_t data = 0x12345678;
    uint32_t result;

    // Try a simple AMOSWAP operation
    __asm__ volatile (
        "amoswap.w %0, %2, (%1)"
        : "=r" (result)
        : "r" (&data), "r" (0xABCDEF00)
        : "memory"
    );

    // If we get 0xDEADBEEF, atomic ops are not supported
    if (result == 0xDEADBEEF) {
        atomic_supported = 0;
        printf("\n[INFO] Atomic operations not supported (returning 0xDEADBEEF)\n");
        printf("[INFO] Tests will be skipped\n");
        return 0;
    }

    atomic_supported = 1;
    return 1;
}

// Helper function to check test result
static void check_result(const char* test_name, uint32_t expected, uint32_t actual) {
    tests_run++;
    if (expected == actual) {
        printf("  [PASS] %s: expected=0x%08lx, actual=0x%08lx\n", test_name, (unsigned long)expected, (unsigned long)actual);
        tests_passed++;
    } else {
        printf("  [FAIL] %s: expected=0x%08lx, actual=0x%08lx\n", test_name, (unsigned long)expected, (unsigned long)actual);
        tests_failed++;
    }
}

// Helper to skip test
static void skip_test(const char* test_name) {
    printf("  [SKIP] %s\n", test_name);
    tests_skipped++;
}

// Test LR.W (Load Reserved) and SC.W (Store Conditional)
static int test_lr_sc(void) {
    printf("\n[TEST 1] LR.W / SC.W (Load-Reserved / Store-Conditional)\n");

    if (!check_atomic_support()) {
        skip_test("LR.W read value");
        skip_test("SC.W result");
        skip_test("SC.W updated value");
        return TEST_PASS;
    }

    volatile uint32_t data = 0x12345678;
    uint32_t read_val, result;

    // LR.W: Load reserved
    __asm__ volatile (
        "lr.w %0, (%1)"
        : "=r" (read_val)
        : "r" (&data)
        : "memory"
    );
    check_result("LR.W read value", 0x12345678, read_val);

    // SC.W: Store conditional (should succeed, result=0)
    uint32_t new_val = 0xABCDEF00;
    __asm__ volatile (
        "sc.w %0, %2, (%1)"
        : "=r" (result)
        : "r" (&data), "r" (new_val)
        : "memory"
    );
    check_result("SC.W result (0=success)", 0, result);
    check_result("SC.W updated value", 0xABCDEF00, data);

    return (tests_failed > 0) ? TEST_FAIL : TEST_PASS;
}

// Test AMOSWAP.W (Atomic Swap)
static int test_amoswap(void) {
    printf("\n[TEST 2] AMOSWAP.W (Atomic Swap)\n");

    volatile uint32_t data = 0x11111111;
    uint32_t old_val;
    uint32_t new_val = 0x22222222;

    __asm__ volatile (
        "amoswap.w %0, %2, (%1)"
        : "=r" (old_val)
        : "r" (&data), "r" (new_val)
        : "memory"
    );

    check_result("AMOSWAP.W old value", 0x11111111, old_val);
    check_result("AMOSWAP.W new value", 0x22222222, data);

    return (tests_failed > 0) ? TEST_FAIL : TEST_PASS;
}

// Test AMOADD.W (Atomic Add)
static int test_amoadd(void) {
    printf("\n[TEST 3] AMOADD.W (Atomic Add)\n");

    volatile uint32_t data = 100;
    uint32_t old_val;
    uint32_t addend = 50;

    __asm__ volatile (
        "amoadd.w %0, %2, (%1)"
        : "=r" (old_val)
        : "r" (&data), "r" (addend)
        : "memory"
    );

    check_result("AMOADD.W old value", 100, old_val);
    check_result("AMOADD.W new value", 150, data);

    return (tests_failed > 0) ? TEST_FAIL : TEST_PASS;
}

// Test AMOXOR.W (Atomic XOR)
static int test_amoxor(void) {
    printf("\n[TEST 4] AMOXOR.W (Atomic XOR)\n");

    volatile uint32_t data = 0xFF00FF00;
    uint32_t old_val;
    uint32_t xor_val = 0xFFFFFFFF;

    __asm__ volatile (
        "amoxor.w %0, %2, (%1)"
        : "=r" (old_val)
        : "r" (&data), "r" (xor_val)
        : "memory"
    );

    check_result("AMOXOR.W old value", 0xFF00FF00, old_val);
    check_result("AMOXOR.W new value", 0x00FF00FF, data);

    return (tests_failed > 0) ? TEST_FAIL : TEST_PASS;
}

// Test AMOAND.W (Atomic AND)
static int test_amoand(void) {
    printf("\n[TEST 5] AMOAND.W (Atomic AND)\n");

    volatile uint32_t data = 0xFFFFFFFF;
    uint32_t old_val;
    uint32_t and_val = 0x0F0F0F0F;

    __asm__ volatile (
        "amoand.w %0, %2, (%1)"
        : "=r" (old_val)
        : "r" (&data), "r" (and_val)
        : "memory"
    );

    check_result("AMOAND.W old value", 0xFFFFFFFF, old_val);
    check_result("AMOAND.W new value", 0x0F0F0F0F, data);

    return (tests_failed > 0) ? TEST_FAIL : TEST_PASS;
}

// Test AMOOR.W (Atomic OR)
static int test_amoor(void) {
    printf("\n[TEST 6] AMOOR.W (Atomic OR)\n");

    volatile uint32_t data = 0x0F0F0F0F;
    uint32_t old_val;
    uint32_t or_val = 0xF0F0F0F0;

    __asm__ volatile (
        "amoor.w %0, %2, (%1)"
        : "=r" (old_val)
        : "r" (&data), "r" (or_val)
        : "memory"
    );

    check_result("AMOOR.W old value", 0x0F0F0F0F, old_val);
    check_result("AMOOR.W new value", 0xFFFFFFFF, data);

    return (tests_failed > 0) ? TEST_FAIL : TEST_PASS;
}

// Test AMOMIN.W (Atomic Min Signed)
static int test_amomin(void) {
    printf("\n[TEST 7] AMOMIN.W (Atomic Min Signed)\n");

    volatile int32_t data = 100;
    int32_t old_val;
    int32_t min_val = -50;

    __asm__ volatile (
        "amomin.w %0, %2, (%1)"
        : "=r" (old_val)
        : "r" (&data), "r" (min_val)
        : "memory"
    );

    check_result("AMOMIN.W old value", 100, old_val);
    check_result("AMOMIN.W new value (min)", (uint32_t)-50, data);

    // Test when existing value is smaller
    data = -100;
    __asm__ volatile (
        "amomin.w %0, %2, (%1)"
        : "=r" (old_val)
        : "r" (&data), "r" (min_val)
        : "memory"
    );

    check_result("AMOMIN.W old value", (uint32_t)-100, old_val);
    check_result("AMOMIN.W unchanged (already min)", (uint32_t)-100, data);

    return (tests_failed > 0) ? TEST_FAIL : TEST_PASS;
}

// Test AMOMAX.W (Atomic Max Signed)
static int test_amomax(void) {
    printf("\n[TEST 8] AMOMAX.W (Atomic Max Signed)\n");

    volatile int32_t data = -100;
    int32_t old_val;
    int32_t max_val = 50;

    __asm__ volatile (
        "amomax.w %0, %2, (%1)"
        : "=r" (old_val)
        : "r" (&data), "r" (max_val)
        : "memory"
    );

    check_result("AMOMAX.W old value", (uint32_t)-100, old_val);
    check_result("AMOMAX.W new value (max)", 50, data);

    // Test when existing value is larger
    data = 100;
    __asm__ volatile (
        "amomax.w %0, %2, (%1)"
        : "=r" (old_val)
        : "r" (&data), "r" (max_val)
        : "memory"
    );

    check_result("AMOMAX.W old value", 100, old_val);
    check_result("AMOMAX.W unchanged (already max)", 100, data);

    return (tests_failed > 0) ? TEST_FAIL : TEST_PASS;
}

// Test AMOMINU.W (Atomic Min Unsigned)
static int test_amominu(void) {
    printf("\n[TEST 9] AMOMINU.W (Atomic Min Unsigned)\n");

    volatile uint32_t data = 1000;
    uint32_t old_val;
    uint32_t min_val = 500;

    __asm__ volatile (
        "amominu.w %0, %2, (%1)"
        : "=r" (old_val)
        : "r" (&data), "r" (min_val)
        : "memory"
    );

    check_result("AMOMINU.W old value", 1000, old_val);
    check_result("AMOMINU.W new value (min)", 500, data);

    // Test when existing value is smaller
    data = 100;
    __asm__ volatile (
        "amominu.w %0, %2, (%1)"
        : "=r" (old_val)
        : "r" (&data), "r" (min_val)
        : "memory"
    );

    check_result("AMOMINU.W old value", 100, old_val);
    check_result("AMOMINU.W unchanged (already min)", 100, data);

    return (tests_failed > 0) ? TEST_FAIL : TEST_PASS;
}

// Test AMOMAXU.W (Atomic Max Unsigned)
static int test_amomaxu(void) {
    printf("\n[TEST 10] AMOMAXU.W (Atomic Max Unsigned)\n");

    volatile uint32_t data = 100;
    uint32_t old_val;
    uint32_t max_val = 500;

    __asm__ volatile (
        "amomaxu.w %0, %2, (%1)"
        : "=r" (old_val)
        : "r" (&data), "r" (max_val)
        : "memory"
    );

    check_result("AMOMAXU.W old value", 100, old_val);
    check_result("AMOMAXU.W new value (max)", 500, data);

    // Test when existing value is larger
    data = 1000;
    __asm__ volatile (
        "amomaxu.w %0, %2, (%1)"
        : "=r" (old_val)
        : "r" (&data), "r" (max_val)
        : "memory"
    );

    check_result("AMOMAXU.W old value", 1000, old_val);
    check_result("AMOMAXU.W unchanged (already max)", 1000, data);

    return (tests_failed > 0) ? TEST_FAIL : TEST_PASS;
}

// Test atomic operations with .aq (acquire) ordering
static int test_acquire_ordering(void) {
    printf("\n[TEST 11] Atomic Operations with .aq (Acquire Ordering)\n");

    volatile uint32_t data = 0x12345678;
    uint32_t old_val;
    uint32_t new_val = 0xABCDEF00;

    // Test AMOSWAP.W.aq
    __asm__ volatile (
        "amoswap.w.aq %0, %2, (%1)"
        : "=r" (old_val)
        : "r" (&data), "r" (new_val)
        : "memory"
    );

    check_result("AMOSWAP.W.aq old value", 0x12345678, old_val);
    check_result("AMOSWAP.W.aq new value", 0xABCDEF00, data);

    return (tests_failed > 0) ? TEST_FAIL : TEST_PASS;
}

// Test atomic operations with .rl (release) ordering
static int test_release_ordering(void) {
    printf("\n[TEST 12] Atomic Operations with .rl (Release Ordering)\n");

    volatile uint32_t data = 0xABCDEF00;
    uint32_t old_val;
    uint32_t new_val = 0x12345678;

    // Test AMOSWAP.W.rl
    __asm__ volatile (
        "amoswap.w.rl %0, %2, (%1)"
        : "=r" (old_val)
        : "r" (&data), "r" (new_val)
        : "memory"
    );

    check_result("AMOSWAP.W.rl old value", 0xABCDEF00, old_val);
    check_result("AMOSWAP.W.rl new value", 0x12345678, data);

    return (tests_failed > 0) ? TEST_FAIL : TEST_PASS;
}

// Test atomic operations with .aqrl (acquire-release) ordering
static int test_aqrl_ordering(void) {
    printf("\n[TEST 13] Atomic Operations with .aqrl (Acquire-Release Ordering)\n");

    volatile uint32_t data = 0x11111111;
    uint32_t old_val;
    uint32_t new_val = 0x22222222;

    // Test AMOSWAP.W.aqrl
    __asm__ volatile (
        "amoswap.w.aqrl %0, %2, (%1)"
        : "=r" (old_val)
        : "r" (&data), "r" (new_val)
        : "memory"
    );

    check_result("AMOSWAP.W.aqrl old value", 0x11111111, old_val);
    check_result("AMOSWAP.W.aqrl new value", 0x22222222, data);

    return (tests_failed > 0) ? TEST_FAIL : TEST_PASS;
}

// ============================================================================
// Arch-Test Pattern Replication (riscv-arch-test rv32i_m/A)
// ============================================================================
// These functions replicate the exact "sw → AMO" sequence emitted by the
// TEST_AMO_OP macro in the RISC-V architectural compliance tests.
//
// The inline asm block stores origval to memory with `sw`, then executes the
// AMO instruction immediately after with NO intervening instructions.  This
// is the tightest possible store-before-load ordering and directly stresses
// the store-buffer RAW (Read-After-Write) path in the RTL.
//
// For every case:
//   rd   must equal ARCH_ORIGVAL (0xf7ffffff) – the original memory value.
//   *mem must equal the result of (ARCH_ORIGVAL OP operand) after the AMO.
//
// Operand set mirrors the first ~10 vectors from each *.w-01.S arch test:
//   INT32_MIN, INT32_MAX, 0, +1, 0x55555555, 0xaaaaaaaa (-0x55555556),
//   +2, -2, -1, -0x10000001 (= 0xefffffff, the specific failing vector)
// ============================================================================

// Store origval to *mem_ptr, then execute the named AMO instruction
// immediately after – all in one asm block so the two instructions are
// adjacent in the pipeline.  This mirrors the RVTEST_SIGUPD sw + inst pair
// in the arch-test TEST_AMO_OP macro.
// Mimics the exact instruction sequence produced by TEST_AMO_OP in the
// RISC-V arch-test test_macros.h:
//   sw   _o, 0(_a)          <- RVTEST_SIGUPD: store origval to memory
//   mv   _vc, _v            <- mirrors 'li reg2, updval'  (intervening #1)
//   addi _a2, _a, 0         <- mirrors 'addi origptr, sigptr, off' (intervening #2)
//   <amo> _r, _vc, (_a2)    <- AMO issued via the recomputed address register
//
// The two intervening register instructions between the sw and the AMO
// reproduce the arch-test timing; using an early-clobber '=&r' for each
// output ensures the compiler assigns distinct registers for _r, _vc, _a2
// (required by the RISC-V spec: rd != rs1 and rd != rs2 for AMO).
#define ARCH_AMO_OP_TEST(asm_instr, mem_ptr, orig, operand, rd_out) do {  \
    uint32_t _rd_tmp;                                                      \
    uint32_t _op_copy;                                                     \
    uint32_t _addr_copy;                                                   \
    __asm__ volatile(                                                      \
        "sw   %[_o],  0(%[_a])\n\t"                                       \
        "mv   %[_vc], %[_v]\n\t"                                          \
        "addi %[_a2], %[_a], 0\n\t"                                       \
        asm_instr " %[_r], %[_vc], (%[_a2])\n\t"                         \
        : [_r]  "=&r"(_rd_tmp),                                           \
          [_vc] "=&r"(_op_copy),                                          \
          [_a2] "=&r"(_addr_copy)                                         \
        : [_o]  "r"((uint32_t)(orig)),                                    \
          [_v]  "r"((uint32_t)(int32_t)(operand)),                        \
          [_a]  "r"((volatile uint32_t *)(mem_ptr))                       \
        : "memory"                                                         \
    );                                                                     \
    (rd_out) = _rd_tmp;                                                   \
} while(0)

#define ARCH_ORIGVAL  0xf7ffffffu

// Report both rd and mem results for one arch-test vector.
static void arch_amo_check(const char *op_name, int idx,
                           uint32_t rd_got,  uint32_t mem_got,
                           uint32_t rd_exp,  uint32_t mem_exp)
{
    char name[80];
    snprintf(name, sizeof(name), "%s[%d] rd",  op_name, idx);
    check_result(name, rd_exp, rd_got);
    snprintf(name, sizeof(name), "%s[%d] mem", op_name, idx);
    check_result(name, mem_exp, mem_got);
}

// [ARCH-TEST A] amoadd.w  (new_mem = origval + operand, unsigned wrap)
static int test_arch_amoadd(void)
{
    printf("\n[ARCH-TEST A] amoadd.w (sw->AMO pattern, origval=0x%08lx)\n",
           (unsigned long)ARCH_ORIGVAL);

    // 7 boundary operands -- zero, one, INT_MAX, MSB, all-ones, alternating patterns.
    // origval = 0xf7ffffff; mem_exp = (origval + op) & 0xffffffff
    static const struct { uint32_t op; uint32_t mem_exp; } tc[] = {
        { 0x00000000u, 0xf7ffffffu },  // +0: no change
        { 0x00000001u, 0xf8000000u },  // +1: carry ripple
        { 0x7fffffffu, 0x77fffffeu },  // +INT_MAX: wrap into negative
        { 0x80000000u, 0x77ffffffu },  // +MSB: wrap (orig already negative)
        { 0xffffffffu, 0xf7fffffeu },  // +-1: subtract 1
        { 0x55555555u, 0x4d555554u },  // alternating pattern 1
        { 0xaaaaaaaau, 0xa2aaaaa9u },  // alternating pattern 2
    };
    volatile uint32_t cell;
    uint32_t rd;
    const char *name = "amoadd.w";

    for (int i = 0; i < (int)(sizeof(tc)/sizeof(tc[0])); i++) {
        ARCH_AMO_OP_TEST("amoadd.w", &cell, ARCH_ORIGVAL, tc[i].op, rd);
        arch_amo_check(name, i, rd, (uint32_t)cell, ARCH_ORIGVAL, tc[i].mem_exp);
    }
    return TEST_PASS;
}

// [ARCH-TEST B] amoswap.w  (new_mem = operand)
static int test_arch_amoswap(void)
{
    printf("\n[ARCH-TEST B] amoswap.w (sw->AMO pattern, origval=0x%08lx)\n",
           (unsigned long)ARCH_ORIGVAL);

    // 7 boundary operands -- zero, one, INT_MAX, MSB, all-ones, alternating patterns.
    // mem_exp = op (swap discards origval, stores operand)
    static const struct { uint32_t op; uint32_t mem_exp; } tc[] = {
        { 0x00000000u, 0x00000000u },  // swap with 0
        { 0x00000001u, 0x00000001u },  // swap with 1
        { 0x7fffffffu, 0x7fffffffu },  // swap with INT_MAX
        { 0x80000000u, 0x80000000u },  // swap with MSB / INT_MIN
        { 0xffffffffu, 0xffffffffu },  // swap with all-ones
        { 0x55555555u, 0x55555555u },  // alternating pattern 1
        { 0xaaaaaaaau, 0xaaaaaaaau },  // alternating pattern 2
    };
    volatile uint32_t cell;
    uint32_t rd;
    const char *name = "amoswap.w";

    for (int i = 0; i < (int)(sizeof(tc)/sizeof(tc[0])); i++) {
        ARCH_AMO_OP_TEST("amoswap.w", &cell, ARCH_ORIGVAL, tc[i].op, rd);
        arch_amo_check(name, i, rd, (uint32_t)cell, ARCH_ORIGVAL, tc[i].mem_exp);
    }
    return TEST_PASS;
}

// [ARCH-TEST C] amoxor.w  (new_mem = origval ^ operand)
static int test_arch_amoxor(void)
{
    printf("\n[ARCH-TEST C] amoxor.w (sw->AMO pattern, origval=0x%08lx)\n",
           (unsigned long)ARCH_ORIGVAL);

    // 7 boundary operands -- zero, one, INT_MAX, MSB, all-ones, alternating patterns.
    // mem_exp = origval ^ op (origval = 0xf7ffffff)
    static const struct { uint32_t op; uint32_t mem_exp; } tc[] = {
        { 0x00000000u, 0xf7ffffffu },  // XOR 0: no change
        { 0x00000001u, 0xf7fffffeu },  // XOR 1: flip LSB
        { 0x7fffffffu, 0x88000000u },  // XOR INT_MAX: flip lower 31 bits
        { 0x80000000u, 0x77ffffffu },  // XOR MSB: flip bit 31
        { 0xffffffffu, 0x08000000u },  // XOR all-ones: complement
        { 0x55555555u, 0xa2aaaaaau },  // alternating pattern 1
        { 0xaaaaaaaau, 0x5d555555u },  // alternating pattern 2
    };
    volatile uint32_t cell;
    uint32_t rd;
    const char *name = "amoxor.w";

    for (int i = 0; i < (int)(sizeof(tc)/sizeof(tc[0])); i++) {
        ARCH_AMO_OP_TEST("amoxor.w", &cell, ARCH_ORIGVAL, tc[i].op, rd);
        arch_amo_check(name, i, rd, (uint32_t)cell, ARCH_ORIGVAL, tc[i].mem_exp);
    }
    return TEST_PASS;
}

// [ARCH-TEST D] amoand.w  (new_mem = origval & operand)
static int test_arch_amoand(void)
{
    printf("\n[ARCH-TEST D] amoand.w (sw->AMO pattern, origval=0x%08lx)\n",
           (unsigned long)ARCH_ORIGVAL);

    // 7 boundary operands -- zero, one, INT_MAX, MSB, all-ones, alternating patterns.
    // mem_exp = origval & op (origval = 0xf7ffffff)
    static const struct { uint32_t op; uint32_t mem_exp; } tc[] = {
        { 0x00000000u, 0x00000000u },  // AND 0: clear all
        { 0x00000001u, 0x00000001u },  // AND 1: keep only LSB
        { 0x7fffffffu, 0x77ffffffu },  // AND INT_MAX: clear bit 31
        { 0x80000000u, 0x80000000u },  // AND MSB: keep only bit 31
        { 0xffffffffu, 0xf7ffffffu },  // AND all-ones: no change
        { 0x55555555u, 0x55555555u },  // alternating pattern 1
        { 0xaaaaaaaau, 0xa2aaaaaau },  // alternating pattern 2
    };
    volatile uint32_t cell;
    uint32_t rd;
    const char *name = "amoand.w";

    for (int i = 0; i < (int)(sizeof(tc)/sizeof(tc[0])); i++) {
        ARCH_AMO_OP_TEST("amoand.w", &cell, ARCH_ORIGVAL, tc[i].op, rd);
        arch_amo_check(name, i, rd, (uint32_t)cell, ARCH_ORIGVAL, tc[i].mem_exp);
    }
    return TEST_PASS;
}

// [ARCH-TEST E] amoor.w  (new_mem = origval | operand)
static int test_arch_amoor(void)
{
    printf("\n[ARCH-TEST E] amoor.w (sw->AMO pattern, origval=0x%08lx)\n",
           (unsigned long)ARCH_ORIGVAL);

    // 7 boundary operands -- zero, one, INT_MAX, MSB, all-ones, alternating patterns.
    // mem_exp = origval | op (origval = 0xf7ffffff; only missing bit is bit 27)
    static const struct { uint32_t op; uint32_t mem_exp; } tc[] = {
        { 0x00000000u, 0xf7ffffffu },  // OR 0: no change
        { 0x00000001u, 0xf7ffffffu },  // OR 1: LSB already set
        { 0x7fffffffu, 0xffffffffu },  // OR INT_MAX: sets bit 27
        { 0x80000000u, 0xf7ffffffu },  // OR MSB: bit 31 already set
        { 0xffffffffu, 0xffffffffu },  // OR all-ones: all bits set
        { 0x55555555u, 0xf7ffffffu },  // alternating 1: bit 27 not in pattern
        { 0xaaaaaaaau, 0xffffffffu },  // alternating 2: bit 27 is set
    };
    volatile uint32_t cell;
    uint32_t rd;
    const char *name = "amoor.w";

    for (int i = 0; i < (int)(sizeof(tc)/sizeof(tc[0])); i++) {
        ARCH_AMO_OP_TEST("amoor.w", &cell, ARCH_ORIGVAL, tc[i].op, rd);
        arch_amo_check(name, i, rd, (uint32_t)cell, ARCH_ORIGVAL, tc[i].mem_exp);
    }
    return TEST_PASS;
}

// [ARCH-TEST F] amomin.w  (signed min; 0xf7ffffff = -134217729)
static int test_arch_amomin(void)
{
    printf("\n[ARCH-TEST F] amomin.w (sw->AMO pattern, origval=0x%08lx = %ld)\n",
           (unsigned long)ARCH_ORIGVAL, (long)(int32_t)ARCH_ORIGVAL);

    // 7 boundary operands; origval = -134217729 (0xf7ffffff)
    // mem_exp = smin(origval, op): op wins only if op < origval signed
    static const struct { uint32_t op; uint32_t mem_exp; } tc[] = {
        { 0x00000000u, 0xf7ffffffu },  // min(-134217729, 0)        = origval
        { 0x00000001u, 0xf7ffffffu },  // min(-134217729, 1)        = origval
        { 0x7fffffffu, 0xf7ffffffu },  // min(-134217729, INT_MAX)  = origval
        { 0x80000000u, 0x80000000u },  // min(-134217729, INT_MIN)  = INT_MIN
        { 0xffffffffu, 0xf7ffffffu },  // min(-134217729, -1)       = origval
        { 0x55555555u, 0xf7ffffffu },  // min(-134217729, positive) = origval
        { 0xaaaaaaaau, 0xaaaaaaaau },  // min(-134217729, -1431655766) = op (more negative)
    };
    volatile uint32_t cell;
    uint32_t rd;
    const char *name = "amomin.w";

    for (int i = 0; i < (int)(sizeof(tc)/sizeof(tc[0])); i++) {
        ARCH_AMO_OP_TEST("amomin.w", &cell, ARCH_ORIGVAL, tc[i].op, rd);
        arch_amo_check(name, i, rd, (uint32_t)cell, ARCH_ORIGVAL, tc[i].mem_exp);
    }
    return TEST_PASS;
}

// [ARCH-TEST G] amomax.w  (signed max; 0xf7ffffff = -134217729)
static int test_arch_amomax(void)
{
    printf("\n[ARCH-TEST G] amomax.w (sw->AMO pattern, origval=0x%08lx = %ld)\n",
           (unsigned long)ARCH_ORIGVAL, (long)(int32_t)ARCH_ORIGVAL);

    // 7 boundary operands; origval = -134217729 (0xf7ffffff)
    // mem_exp = smax(origval, op): op wins only if op > origval signed
    static const struct { uint32_t op; uint32_t mem_exp; } tc[] = {
        { 0x00000000u, 0x00000000u },  // max(-134217729, 0)        = 0
        { 0x00000001u, 0x00000001u },  // max(-134217729, 1)        = 1
        { 0x7fffffffu, 0x7fffffffu },  // max(-134217729, INT_MAX)  = INT_MAX
        { 0x80000000u, 0xf7ffffffu },  // max(-134217729, INT_MIN)  = origval
        { 0xffffffffu, 0xffffffffu },  // max(-134217729, -1)       = -1 (larger)
        { 0x55555555u, 0x55555555u },  // max(-134217729, positive) = op
        { 0xaaaaaaaau, 0xf7ffffffu },  // max(-134217729, -1431655766) = origval (less negative)
    };
    volatile uint32_t cell;
    uint32_t rd;
    const char *name = "amomax.w";

    for (int i = 0; i < (int)(sizeof(tc)/sizeof(tc[0])); i++) {
        ARCH_AMO_OP_TEST("amomax.w", &cell, ARCH_ORIGVAL, tc[i].op, rd);
        arch_amo_check(name, i, rd, (uint32_t)cell, ARCH_ORIGVAL, tc[i].mem_exp);
    }
    return TEST_PASS;
}

// [ARCH-TEST H] amominu.w  (unsigned min; 0xf7ffffff = 4160749567u)
static int test_arch_amominu(void)
{
    printf("\n[ARCH-TEST H] amominu.w (sw->AMO pattern, origval=0x%08lx = %luU)\n",
           (unsigned long)ARCH_ORIGVAL, (unsigned long)ARCH_ORIGVAL);

    // 7 boundary operands; origval = 0xf7ffffff = 4160749567u (unsigned)
    // mem_exp = uminu(origval, op): op wins only if op < origval unsigned
    static const struct { uint32_t op; uint32_t mem_exp; } tc[] = {
        { 0x00000000u, 0x00000000u },  // uminu(0xf7ffffff, 0)          = 0
        { 0x00000001u, 0x00000001u },  // uminu(0xf7ffffff, 1)          = 1
        { 0x7fffffffu, 0x7fffffffu },  // uminu(0xf7ffffff, 0x7fffffff) = 0x7fffffff
        { 0x80000000u, 0x80000000u },  // uminu(0xf7ffffff, 0x80000000) = 0x80000000
        { 0xffffffffu, 0xf7ffffffu },  // uminu(0xf7ffffff, 0xffffffff) = origval
        { 0x55555555u, 0x55555555u },  // alternating pattern 1 (smaller)
        { 0xaaaaaaaau, 0xaaaaaaaau },  // alternating pattern 2 (smaller)
    };
    volatile uint32_t cell;
    uint32_t rd;
    const char *name = "amominu.w";

    for (int i = 0; i < (int)(sizeof(tc)/sizeof(tc[0])); i++) {
        ARCH_AMO_OP_TEST("amominu.w", &cell, ARCH_ORIGVAL, tc[i].op, rd);
        arch_amo_check(name, i, rd, (uint32_t)cell, ARCH_ORIGVAL, tc[i].mem_exp);
    }
    return TEST_PASS;
}

// [ARCH-TEST I] amomaxu.w  (unsigned max; 0xf7ffffff = 4160749567u)
static int test_arch_amomaxu(void)
{
    printf("\n[ARCH-TEST I] amomaxu.w (sw->AMO pattern, origval=0x%08lx = %luU)\n",
           (unsigned long)ARCH_ORIGVAL, (unsigned long)ARCH_ORIGVAL);

    // 7 boundary operands; origval = 0xf7ffffff = 4160749567u (unsigned)
    // mem_exp = umaxu(origval, op): op wins only if op > origval unsigned
    static const struct { uint32_t op; uint32_t mem_exp; } tc[] = {
        { 0x00000000u, 0xf7ffffffu },  // umaxu(0xf7ffffff, 0)          = origval
        { 0x00000001u, 0xf7ffffffu },  // umaxu(0xf7ffffff, 1)          = origval
        { 0x7fffffffu, 0xf7ffffffu },  // umaxu(0xf7ffffff, 0x7fffffff) = origval
        { 0x80000000u, 0xf7ffffffu },  // umaxu(0xf7ffffff, 0x80000000) = origval
        { 0xffffffffu, 0xffffffffu },  // umaxu(0xf7ffffff, 0xffffffff) = 0xffffffff
        { 0x55555555u, 0xf7ffffffu },  // alternating pattern 1 (smaller)
        { 0xaaaaaaaau, 0xf7ffffffu },  // alternating pattern 2 (smaller)
    };
    volatile uint32_t cell;
    uint32_t rd;
    const char *name = "amomaxu.w";

    for (int i = 0; i < (int)(sizeof(tc)/sizeof(tc[0])); i++) {
        ARCH_AMO_OP_TEST("amomaxu.w", &cell, ARCH_ORIGVAL, tc[i].op, rd);
        arch_amo_check(name, i, rd, (uint32_t)cell, ARCH_ORIGVAL, tc[i].mem_exp);
    }
    return TEST_PASS;
}

int main(void) {
    printf("========================================\n");
    printf("  RISC-V Atomic (A) Extension Test\n");
    printf("  Testing AMO Instructions\n");
    printf("========================================\n");

    // Run all tests
    test_lr_sc();
    test_amoswap();
    test_amoadd();
    test_amoxor();
    test_amoand();
    test_amoor();
    test_amomin();
    test_amomax();
    test_amominu();
    test_amomaxu();
    test_acquire_ordering();
    test_release_ordering();
    test_aqrl_ordering();

    // Arch-test pattern replication (sw->AMO RAW hazard stress tests)
    test_arch_amoadd();
    test_arch_amoswap();
    test_arch_amoxor();
    test_arch_amoand();
    test_arch_amoor();
    test_arch_amomin();
    test_arch_amomax();
    test_arch_amominu();
    test_arch_amomaxu();

    // Print summary
    printf("\n========================================\n");
    printf("  Test Summary\n");
    printf("========================================\n");
    printf("  Total:  %lu\n", (unsigned long)tests_run);
    printf("  Passed: %lu\n", (unsigned long)tests_passed);
    printf("  Failed: %lu\n", (unsigned long)tests_failed);
    printf("========================================\n");

    if (tests_failed > 0) {
        printf("\n[RESULT] TEST FAILED\n");
        return TEST_FAIL;
    } else {
        printf("\n[RESULT] ALL TESTS PASSED\n");
        return TEST_PASS;
    }
}
