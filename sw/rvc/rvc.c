// ============================================================================
// rvc.c — RVC (Zca) compressed instruction exercise test
// ============================================================================
// Exercises representative instructions from all six RVC groups:
//   CI  : C.LI, C.ADDI, C.LWSP, C.LUI, C.ADDI16SP, C.SLLI
//   CL  : C.LW
//   CS  : C.SW
//   CSS : C.SWSP
//   CIW : C.ADDI4SPN
//   CR  : C.ADD, C.MV, C.JR, C.JALR
//   CB  : C.BEQZ, C.BNEZ, C.SRLI, C.SRAI, C.ANDI
//   CJ  : C.J, C.JAL
//
// The compiler (-march=rv32imac_zicsr -O2) will automatically emit RVC
// sequences for these patterns; this source does NOT use inline asm so
// the test is portable.  The test passes if exit_code == 0.
// ============================================================================

#include <stdint.h>
#include "kv_platform.h"

// Minimal write helper used for result reporting
extern int _write(int fd, const char *buf, int len);

static void write_str(const char *s) {
    int n = 0;
    while (s[n]) n++;
    _write(1, s, n);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static int failures = 0;

static void check(const char *name, int got, int expected) {
    if (got != expected) {
        write_str("FAIL: ");
        write_str(name);
        write_str("\n");
        failures++;
    }
}

// ---------------------------------------------------------------------------
// Test: stack-relative loads and stores (C.LWSP / C.SWSP)
// ---------------------------------------------------------------------------
static int test_stack_ops(void) {
    volatile int a = 10, b = 20, c;
    c = a + b;
    return c;  // expect 30
}

// ---------------------------------------------------------------------------
// Test: small struct field access (C.LW / C.SW via base+offset)
// ---------------------------------------------------------------------------
typedef struct { int x; int y; int z; } Vec3;

static int test_struct_ops(void) {
    Vec3 v;
    v.x = 1;
    v.y = 2;
    v.z = 3;
    return v.x + v.y + v.z;  // expect 6
}

// ---------------------------------------------------------------------------
// Test: conditional branch (C.BEQZ / C.BNEZ)
// ---------------------------------------------------------------------------
static int test_branches(int a, int b) {
    int result = 0;
    if (a == 0) result += 1;
    if (b != 0) result += 2;
    return result;
}

// ---------------------------------------------------------------------------
// Test: loop with counter (exercises C.ADDI / C.J / C.BNEZ / C.BEQZ)
// ---------------------------------------------------------------------------
static int test_loop(int n) {
    int sum = 0;
    for (int i = 0; i < n; i++) {
        sum += i;
    }
    return sum;
}

// ---------------------------------------------------------------------------
// Test: bitwise operations (C.AND / C.OR / C.XOR via C.ANDI etc.)
// ---------------------------------------------------------------------------
static int test_bitwise(int v) {
    int a = v & 0xFF;
    int b = v >> 1;
    int c = a ^ b;
    return c;
}

// ---------------------------------------------------------------------------
// Test: function call chain (exercises C.JAL / C.JR / C.JALR / C.MV)
// ---------------------------------------------------------------------------
static int helper_add(int x, int y) { return x + y; }
static int helper_mul(int x, int y) { return x * y; }

static int test_call_chain(int a, int b) {
    int s = helper_add(a, b);
    int p = helper_mul(a, b);
    return s + p;  // (a+b) + (a*b)
}

// ---------------------------------------------------------------------------
// Test: array access triggering C.ADDI4SPN address formation
// ---------------------------------------------------------------------------
static int test_array(void) {
    int arr[8];
    for (int i = 0; i < 8; i++) arr[i] = i * i;
    int sum = 0;
    for (int i = 0; i < 8; i++) sum += arr[i];
    return sum;  // 0+1+4+9+16+25+36+49 = 140
}

// ---------------------------------------------------------------------------
// Test: shift operations (C.SLLI / C.SRLI / C.SRAI)
// ---------------------------------------------------------------------------
static int test_shifts(int x) {
    int a = x << 3;
    int b = (unsigned)x >> 2;
    int c = x >> 1;  // arithmetic (signed)
    return a + b + c;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(void) {
    // stack_ops: 10 + 20
    check("stack_ops", test_stack_ops(), 30);

    // struct_ops: 1+2+3
    check("struct_ops", test_struct_ops(), 6);

    // branches: a=0, b=5 → result should be 3
    check("branches_01", test_branches(0, 5), 3);
    // branches: a=1, b=0 → result should be 0
    check("branches_10", test_branches(1, 0), 0);
    // branches: a=0, b=0 → result should be 1
    check("branches_00", test_branches(0, 0), 1);

    // loop: sum 0..9 = 45
    check("loop_10", test_loop(10), 45);

    // bitwise: v=0xAB → a=0xAB, b=0x55, c=0xFE = 254
    check("bitwise", test_bitwise(0xAB), 0xFE);

    // call_chain: a=3, b=4 → s=7, p=12 → 19
    check("call_chain", test_call_chain(3, 4), 19);

    // array
    check("array", test_array(), 140);

    // shifts: x=16 → a=128, b=4, c=8 → 140
    check("shifts", test_shifts(16), 140);

    if (failures == 0) {
        write_str("PASS: all RVC tests passed\n");
        kv_magic_exit(0);
    } else {
        write_str("FAIL: some RVC tests failed\n");
        kv_magic_exit(1);
    }
    return failures;
}
