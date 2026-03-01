// ============================================================================
// File: divmul.c
// Project: KV32 RISC-V Processor
// Description: RV32M boundary-case test: multiply/divide corner cases per RISC-V spec
//
// Covers: division by zero, signed overflow (INT32_MIN / -1),
// MULH upper-32-bit results, and REM/REMU remainder semantics.
// ============================================================================

#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>

#define INT32_MAX_VAL   ((int32_t)0x7FFFFFFF)   /*  2147483647 */
#define INT32_MIN_VAL   ((int32_t)0x80000000)   /* -2147483648 */
#define UINT32_MAX_VAL  ((uint32_t)0xFFFFFFFF)

static int pass_count = 0;
static int fail_count = 0;

/* ---- helpers ------------------------------------------------------------ */

static void check32s(const char *name, int32_t got, int32_t expected)
{
    if (got == expected) {
        printf("  PASS  %s = 0x%08" PRIx32 " (%" PRId32 ")\n", name, (uint32_t)got, got);
        pass_count++;
    } else {
        printf("  FAIL  %s: got 0x%08" PRIx32 " (%" PRId32 "), expected 0x%08" PRIx32 " (%" PRId32 ")\n",
               name, (uint32_t)got, got, (uint32_t)expected, expected);
        fail_count++;
    }
}

static void check32u(const char *name, uint32_t got, uint32_t expected)
{
    if (got == expected) {
        printf("  PASS  %s = 0x%08" PRIx32 " (%" PRIu32 ")\n", name, got, got);
        pass_count++;
    } else {
        printf("  FAIL  %s: got 0x%08" PRIx32 " (%" PRIu32 "), expected 0x%08" PRIx32 " (%" PRIu32 ")\n",
               name, got, got, expected, expected);
        fail_count++;
    }
}

/* Force compiler to actually emit the M-extension instruction by using
 * volatile intermediates and inline-asm wrappers.                       */

static int32_t do_mul(int32_t a, int32_t b)
{
    int32_t r;
    __asm__ volatile ("mul %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}
static int32_t do_mulh(int32_t a, int32_t b)
{
    int32_t r;
    __asm__ volatile ("mulh %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}
static int32_t do_mulhsu(int32_t a, uint32_t b)
{
    int32_t r;
    __asm__ volatile ("mulhsu %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}
static uint32_t do_mulhu(uint32_t a, uint32_t b)
{
    uint32_t r;
    __asm__ volatile ("mulhu %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}
static int32_t do_div(int32_t a, int32_t b)
{
    int32_t r;
    __asm__ volatile ("div %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}
static uint32_t do_divu(uint32_t a, uint32_t b)
{
    uint32_t r;
    __asm__ volatile ("divu %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}
static int32_t do_rem(int32_t a, int32_t b)
{
    int32_t r;
    __asm__ volatile ("rem %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}
static uint32_t do_remu(uint32_t a, uint32_t b)
{
    uint32_t r;
    __asm__ volatile ("remu %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}

/* ========================================================================= */

static void test_mul(void)
{
    printf("\n[MUL] lower 32 bits of signed product\n");

    /* Normal cases */
    check32s("mul(0, 0)",              do_mul(0, 0),               0);
    check32s("mul(1, 1)",              do_mul(1, 1),               1);
    check32s("mul(-1, -1)",            do_mul(-1, -1),             1);
    check32s("mul(1, -1)",             do_mul(1, -1),             -1);
    check32s("mul(2, 3)",              do_mul(2, 3),               6);
    check32s("mul(-2, 3)",             do_mul(-2, 3),             -6);

    /* Boundary: INT32_MAX × 1 */
    check32s("mul(INT32_MAX, 1)",      do_mul(INT32_MAX_VAL, 1),   INT32_MAX_VAL);

    /* Boundary: INT32_MIN × 1 */
    check32s("mul(INT32_MIN, 1)",      do_mul(INT32_MIN_VAL, 1),   INT32_MIN_VAL);

    /* Boundary: INT32_MIN × -1 = INT32_MIN (overflow, truncated to 32b) */
    check32s("mul(INT32_MIN, -1)",     do_mul(INT32_MIN_VAL, -1),  INT32_MIN_VAL);

    /* Boundary: INT32_MAX × INT32_MAX — lower 32 bits = 1 */
    /* 0x7FFFFFFF^2 = 0x3FFFFFFF_00000001 → lower 32 = 0x00000001 */
    check32s("mul(INT32_MAX, INT32_MAX)", do_mul(INT32_MAX_VAL, INT32_MAX_VAL), 1);

    /* Boundary: INT32_MAX × 2 overflows into negative */
    /* 0x7FFFFFFF × 2 = 0xFFFFFFFE → -2 as signed */
    check32s("mul(INT32_MAX, 2)",      do_mul(INT32_MAX_VAL, 2),  -2);
}

static void test_mulh(void)
{
    printf("\n[MULH] upper 32 bits of signed × signed\n");

    check32s("mulh(0, 0)",            do_mulh(0, 0),              0);
    check32s("mulh(1, 1)",            do_mulh(1, 1),              0);
    check32s("mulh(-1, 1)",           do_mulh(-1, 1),            -1);
    check32s("mulh(-1, -1)",          do_mulh(-1, -1),            0);

    /* INT32_MAX × INT32_MAX: full product = 0x3FFFFFFF_00000001, upper = 0x3FFFFFFF */
    check32s("mulh(INT32_MAX, INT32_MAX)", do_mulh(INT32_MAX_VAL, INT32_MAX_VAL),
             (int32_t)0x3FFFFFFF);

    /* INT32_MIN × INT32_MIN: full product = 0x40000000_00000000, upper = 0x40000000 */
    check32s("mulh(INT32_MIN, INT32_MIN)", do_mulh(INT32_MIN_VAL, INT32_MIN_VAL),
             (int32_t)0x40000000);

    /* INT32_MIN × -1: full product = 2^31, upper = 0, lower = INT32_MIN */
    check32s("mulh(INT32_MIN, -1)",   do_mulh(INT32_MIN_VAL, -1), 0);

    /* INT32_MIN × INT32_MAX: result negative, upper = 0xC0000000 */
    check32s("mulh(INT32_MIN, INT32_MAX)", do_mulh(INT32_MIN_VAL, INT32_MAX_VAL),
             (int32_t)0xC0000000);
}

static void test_mulhsu(void)
{
    printf("\n[MULHSU] upper 32 bits of signed × unsigned\n");

    check32s("mulhsu(0, 0)",          do_mulhsu(0, 0),             0);
    check32s("mulhsu(1, 1)",          do_mulhsu(1, 1),             0);
    check32s("mulhsu(-1, 1)",         do_mulhsu(-1, 1),           -1);

    /* -1 × UINT32_MAX: treat -1 as -1 signed, UINT32_MAX unsigned
     * product = -0xFFFFFFFF = -4294967295
     * = 0xFFFFFFFF_00000001 in 64-bit two's complement; upper = 0xFFFFFFFF = -1 */
    check32s("mulhsu(-1, UINT32_MAX)", do_mulhsu(-1, UINT32_MAX_VAL), -1);

    /* INT32_MAX × UINT32_MAX: 0x7FFFFFFF × 0xFFFFFFFF
     * = 0x7FFFFFFE_80000001; upper = 0x7FFFFFFE */
    check32s("mulhsu(INT32_MAX, UINT32_MAX)", do_mulhsu(INT32_MAX_VAL, UINT32_MAX_VAL),
             (int32_t)0x7FFFFFFE);

    /* INT32_MIN × UINT32_MAX: 0x80000000 × 0xFFFFFFFF (unsigned half = 2^31)
     * full = -(2^31) × (2^32 - 1) = -2^63 + 2^31
     * = 0x80000000_80000000 ; upper = 0x80000000 */
    check32s("mulhsu(INT32_MIN, UINT32_MAX)", do_mulhsu(INT32_MIN_VAL, UINT32_MAX_VAL),
             INT32_MIN_VAL);
}

static void test_mulhu(void)
{
    printf("\n[MULHU] upper 32 bits of unsigned × unsigned\n");

    check32u("mulhu(0, 0)",           do_mulhu(0, 0),              0);
    check32u("mulhu(1, 1)",           do_mulhu(1, 1),              0);
    check32u("mulhu(1, UINT32_MAX)",  do_mulhu(1, UINT32_MAX_VAL), 0);

    /* UINT32_MAX × UINT32_MAX: 0xFFFFFFFF^2 = 0xFFFFFFFE_00000001; upper = 0xFFFFFFFE */
    check32u("mulhu(UINT32_MAX, UINT32_MAX)", do_mulhu(UINT32_MAX_VAL, UINT32_MAX_VAL),
             0xFFFFFFFEU);

    /* 0x80000000 × 0x80000000 = 0x40000000_00000000; upper = 0x40000000 */
    check32u("mulhu(0x80000000, 0x80000000)", do_mulhu(0x80000000U, 0x80000000U),
             0x40000000U);
}

static void test_div(void)
{
    printf("\n[DIV] signed division\n");

    /* Normal */
    check32s("div(10, 3)",            do_div(10, 3),               3);
    check32s("div(-10, 3)",           do_div(-10, 3),             -3);
    check32s("div(10, -3)",           do_div(10, -3),             -3);
    check32s("div(-10, -3)",          do_div(-10, -3),             3);
    check32s("div(0, 5)",             do_div(0, 5),                0);
    check32s("div(1, 1)",             do_div(1, 1),                1);
    check32s("div(-1, 1)",            do_div(-1, 1),              -1);
    check32s("div(INT32_MAX, 1)",     do_div(INT32_MAX_VAL, 1),    INT32_MAX_VAL);
    check32s("div(INT32_MIN, 1)",     do_div(INT32_MIN_VAL, 1),    INT32_MIN_VAL);

    /* Spec: division by zero → quotient = -1 */
    check32s("div(1, 0)",             do_div(1, 0),               -1);
    check32s("div(-1, 0)",            do_div(-1, 0),              -1);
    check32s("div(INT32_MAX, 0)",     do_div(INT32_MAX_VAL, 0),   -1);
    check32s("div(INT32_MIN, 0)",     do_div(INT32_MIN_VAL, 0),   -1);

    /* Spec: signed overflow INT32_MIN / -1 → INT32_MIN */
    check32s("div(INT32_MIN, -1)",    do_div(INT32_MIN_VAL, -1),   INT32_MIN_VAL);
}

static void test_divu(void)
{
    printf("\n[DIVU] unsigned division\n");

    /* Normal */
    check32u("divu(10, 3)",           do_divu(10, 3),              3);
    check32u("divu(0, 5)",            do_divu(0, 5),               0);
    check32u("divu(UINT32_MAX, 1)",   do_divu(UINT32_MAX_VAL, 1),  UINT32_MAX_VAL);
    check32u("divu(UINT32_MAX, 2)",   do_divu(UINT32_MAX_VAL, 2),  0x7FFFFFFFU);

    /* arch-test patterns: large unsigned dividends (32 iterations, clz=0) */
    check32u("divu(0x10000, 0x10000)",  do_divu(0x10000U, 0x10000U),    1U);
    check32u("divu(0x10001, 0x10000)",  do_divu(0x10001U, 0x10000U),    1U);
    check32u("divu(0xffffffff, 3)",     do_divu(UINT32_MAX_VAL, 3U),    0x55555555U);
    check32u("divu(0x80000000, 3)",     do_divu(0x80000000U, 3U),       0x2aaaaaaaU);

    /* Spec: division by zero → UINT32_MAX */
    check32u("divu(1, 0)",            do_divu(1, 0),               UINT32_MAX_VAL);
    check32u("divu(0, 0)",            do_divu(0, 0),               UINT32_MAX_VAL);
    check32u("divu(UINT32_MAX, 0)",   do_divu(UINT32_MAX_VAL, 0),  UINT32_MAX_VAL);
}

static void test_rem(void)
{
    printf("\n[REM] signed remainder\n");

    /* Normal */
    check32s("rem(10, 3)",            do_rem(10, 3),               1);
    check32s("rem(-10, 3)",           do_rem(-10, 3),             -1);
    check32s("rem(10, -3)",           do_rem(10, -3),              1);
    check32s("rem(-10, -3)",          do_rem(-10, -3),            -1);
    check32s("rem(0, 5)",             do_rem(0, 5),                0);
    check32s("rem(7, 7)",             do_rem(7, 7),                0);
    check32s("rem(INT32_MAX, 2)",     do_rem(INT32_MAX_VAL, 2),    1);
    check32s("rem(INT32_MIN, 2)",     do_rem(INT32_MIN_VAL, 2),    0);

    /* Spec: division by zero → remainder = dividend */
    check32s("rem(1, 0)",             do_rem(1, 0),                1);
    check32s("rem(-1, 0)",            do_rem(-1, 0),              -1);
    check32s("rem(INT32_MAX, 0)",     do_rem(INT32_MAX_VAL, 0),    INT32_MAX_VAL);
    check32s("rem(INT32_MIN, 0)",     do_rem(INT32_MIN_VAL, 0),    INT32_MIN_VAL);

    /* Spec: signed overflow INT32_MIN % -1 → 0 */
    check32s("rem(INT32_MIN, -1)",    do_rem(INT32_MIN_VAL, -1),   0);

    /* arch-test patterns: same dividend 0xb505, varying small negative divisors.
     * Remainder sign always matches the dividend (positive here). */
    check32s("rem(0xb505, -2)",       do_rem(0xb505, -2),          1);
    check32s("rem(0xb505, -3)",       do_rem(0xb505, -3),          0);
    check32s("rem(0xb505, -5)",       do_rem(0xb505, -5),          1);
    check32s("rem(0xb505, -9)",       do_rem(0xb505, -9),          0);
    check32s("rem(0xb505, -0x11)",    do_rem(0xb505, -0x11),       0x10);
    check32s("rem(0xb505, -0x21)",    do_rem(0xb505, -0x21),       9);

    /* Large negative dividend */
    check32s("rem(INT32_MIN, 0xb505)", do_rem(INT32_MIN_VAL, 0xb505), (int32_t)-0xa2ec);
}

static void test_remu(void)
{
    printf("\n[REMU] unsigned remainder\n");

    /* Normal */
    check32u("remu(10, 3)",           do_remu(10, 3),              1);
    check32u("remu(0, 5)",            do_remu(0, 5),               0);
    check32u("remu(UINT32_MAX, 2)",   do_remu(UINT32_MAX_VAL, 2),  1);
    check32u("remu(UINT32_MAX, UINT32_MAX)", do_remu(UINT32_MAX_VAL, UINT32_MAX_VAL), 0);

    /* Spec: division by zero → remainder = dividend */
    check32u("remu(1, 0)",            do_remu(1, 0),               1);
    check32u("remu(0, 0)",            do_remu(0, 0),               0);
    check32u("remu(UINT32_MAX, 0)",   do_remu(UINT32_MAX_VAL, 0),  UINT32_MAX_VAL);

    /* arch-test patterns: power-of-2 divisor, 32-iteration unsigned divides */
    check32u("remu(0x10000, 0x10000)",   do_remu(0x10000U, 0x10000U),    0U);
    check32u("remu(0xffffffff, 0x10000)", do_remu(UINT32_MAX_VAL, 0x10000U), 0xffffU);
    check32u("remu(0, 0x10000)",         do_remu(0U, 0x10000U),           0U);
    check32u("remu(0x10000, 0xfffffffe)", do_remu(0x10000U, 0xfffffffeU),  0x10000U);
    check32u("remu(0xffffffff, 3)",      do_remu(UINT32_MAX_VAL, 3U),     0U);
    check32u("remu(0x80000000, 3)",      do_remu(0x80000000U, 3U),        2U);
}

/* ========================================================================= */

int main(void)
{
    printf("==========================================\n");
    printf("RV32M Boundary Test\n");
    printf("==========================================\n");

    test_mul();
    test_mulh();
    test_mulhsu();
    test_mulhu();
    test_div();
    test_divu();
    test_rem();
    test_remu();

    printf("\n==========================================\n");
    printf("Results: %d passed, %d failed\n", pass_count, fail_count);
    if (fail_count == 0)
        printf("All tests PASSED!\n");
    else
        printf("*** SOME TESTS FAILED ***\n");
    printf("==========================================\n");

    return fail_count;
}
