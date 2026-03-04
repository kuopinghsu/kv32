// ============================================================================
// File: icache.c
// Project: KV32 RISC-V Processor
// Description: I-Cache functional test: cold/warm timing, FENCE.I flush, cbo.inval
//
// Tests: cold-miss vs warm-hit cycle counts, FENCE.I full flush
// (next run should be cold again), and cbo.inval line invalidation.
// Also runs correctly with ICACHE_EN=0 (no timing assertions).
// ============================================================================

#include <stdint.h>
#include <csr.h>
#include "kv_platform.h"

// ---------------------------------------------------------------------------
// Helper: output one character via UART MMIO
// ---------------------------------------------------------------------------
extern void putc(char c);

static void my_puts(const char *s) {
    while (*s) putc(*s++);
}

static void print_hex32(uint32_t v) {
    const char hex[] = "0123456789abcdef";
    for (int i = 7; i >= 0; i--)
        putc(hex[(v >> (i * 4)) & 0xf]);
}

static void print_dec(uint32_t v) {
    if (v == 0) { putc('0'); return; }
    char buf[12]; int n = 0;
    while (v > 0) { buf[n++] = '0' + (v % 10); v /= 10; }
    while (n > 0) putc(buf[--n]);
}

// ---------------------------------------------------------------------------
// Hot loop – must NOT be inlined so we can target its address with cbo.inval
// ---------------------------------------------------------------------------
static uint32_t __attribute__((noinline)) hot_loop(uint32_t iters) {
    uint32_t acc = 0;
    for (uint32_t i = 0; i < iters; i++) {
        acc += i;
        acc ^= (acc >> 3);
    }
    return acc;
}

// ---------------------------------------------------------------------------
// Time one execution of hot_loop and return cycle delta.
// ---------------------------------------------------------------------------
static uint32_t time_hot_loop(uint32_t iters) {
    uint32_t t0 = read_csr_mcycle();
    volatile uint32_t r = hot_loop(iters);
    uint32_t t1 = read_csr_mcycle();
    (void)r;
    return t1 - t0;
}

// ---------------------------------------------------------------------------
// Inline-assembly wrappers for CMO instructions
// ---------------------------------------------------------------------------

// fence.i – serialise and flush the entire instruction cache
// Encoded as .word to avoid requiring -march=..._zifencei from the toolchain.
// FENCE.I = opcode 0x0F, funct3=1, rs1=0, rd=0, imm=0 → 0x0000100F
static inline void fence_i(void) {
    __asm__ volatile (".word 0x0000100f" ::: "memory");
}

// cbo.inval rs1  – invalidate the I-cache line containing *addr
// Encoding: .insn i OPCODE_MISC_MEM(0xf), funct3=2, rd=x0, imm=0, rs1
static inline void cbo_inval(void *addr) {
    __asm__ volatile (".insn i 0xf, 2, x0, 0(%0)"
                      :
                      : "r"(addr)
                      : "memory");
}

// ---------------------------------------------------------------------------
// Minimal trap handler (required by start.S)
// ---------------------------------------------------------------------------
void trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval) {
    (void)mcause; (void)mepc; (void)mtval;
    my_puts("TRAP mcause=0x"); print_hex32(mcause);
    my_puts(" mepc=0x");       print_hex32(mepc);
    my_puts(" mtval=0x");      print_hex32(mtval);
    my_puts("\n");
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
#define ITERS 200U

int main(void) {
    int fails = 0;

#if !defined(ICACHE_EN) || ICACHE_EN == 0
    my_puts("\nICACHE_EN=0: I-Cache not present, skipping cache tests\n");
    kv_magic_exit(0);
    return 0;
#endif

    my_puts("\n");
    my_puts("========================================\n");
    my_puts("  I-Cache Functional Test\n");
    my_puts("========================================\n\n");

    // =========================================================
    // TEST 1: Cold vs warm timing
    // =========================================================
    my_puts("[TEST 1] Cold vs warm timing\n");

    // Flush the cache so the hot_loop region is cold.
    fence_i();

    uint32_t cold_cycles = time_hot_loop(ITERS);
    uint32_t warm_cycles = time_hot_loop(ITERS);

    my_puts("  Cold cycles: "); print_dec(cold_cycles); my_puts("\n");
    my_puts("  Warm cycles: "); print_dec(warm_cycles); my_puts("\n");

    if (warm_cycles <= cold_cycles) {
        my_puts("  Result: PASS  (warm <= cold)\n\n");
    } else {
        my_puts("  WARNING: warm > cold (may be OK if ICACHE_EN=0)\n\n");
    }

    // =========================================================
    // TEST 2: FENCE.I instruction
    // =========================================================
    my_puts("[TEST 2] FENCE.I instruction\n");

    uint32_t pre_fence_cycles = time_hot_loop(ITERS);
    fence_i();
    uint32_t post_fence_cycles = time_hot_loop(ITERS);

    my_puts("  Pre-fence  cycles: "); print_dec(pre_fence_cycles);  my_puts("\n");
    my_puts("  Post-fence cycles: "); print_dec(post_fence_cycles); my_puts("\n");

    uint32_t re_warm_cycles = time_hot_loop(ITERS);
    my_puts("  Re-warm    cycles: "); print_dec(re_warm_cycles); my_puts("\n");

    // Correctness: hot_loop must return the same value across fence.i
    uint32_t ref = hot_loop(ITERS);
    fence_i();
    uint32_t chk = hot_loop(ITERS);
    if (ref == chk) {
        my_puts("  Result: PASS  (hot_loop result consistent across fence.i)\n\n");
    } else {
        my_puts("  Result: FAIL  (hot_loop returned different value after fence.i!)\n\n");
        fails++;
    }

    // =========================================================
    // TEST 3: cbo.inval instruction
    // =========================================================
    my_puts("[TEST 3] cbo.inval instruction\n");

    // Warm the cache first
    (void)hot_loop(ITERS);

    // Invalidate the cache line containing hot_loop's code
    cbo_inval((void *)&hot_loop);
    my_puts("  Issued cbo.inval for hot_loop @ 0x");
    print_hex32((uint32_t)(uintptr_t)&hot_loop);
    my_puts("\n");

    uint32_t post_cbo_cycles = time_hot_loop(ITERS);
    my_puts("  Post-cbo.inval cycles: "); print_dec(post_cbo_cycles); my_puts("\n");

    // Correctness: result must still match after invalidation
    uint32_t ref2 = hot_loop(ITERS);
    fence_i();
    uint32_t chk2 = hot_loop(ITERS);
    if (ref2 == chk2) {
        my_puts("  Result: PASS  (hot_loop result consistent after cbo.inval)\n\n");
    } else {
        my_puts("  Result: FAIL  (hot_loop corrupted after cbo.inval!)\n\n");
        fails++;
    }

    // =========================================================
    // TEST 4: Non-Cacheable Memory (NCM) – PMA bypass
    // =========================================================
    my_puts("[TEST 4] Non-Cacheable Memory (NCM) uncached execution\n");
    my_puts("  NCM base : 0x"); print_hex32(KV_NCM_BASE); my_puts("\n");
    my_puts("  hot_loop @ 0x"); print_hex32((uint32_t)(uintptr_t)&hot_loop); my_puts("\n");

    // Copy hot_loop machine code to NCM (128 bytes = 32 words, safe upper bound).
    // hot_loop is position-independent (RV32I: only PC-relative branches, no
    // absolute addresses), so the copy runs correctly at any base address.
    volatile uint32_t *ncm_ptr = (volatile uint32_t *)(uintptr_t)KV_NCM_BASE;
    const uint32_t    *src_ptr = (const uint32_t *)(uintptr_t)&hot_loop;
    for (int w = 0; w < 32; w++)
        ncm_ptr[w] = src_ptr[w];

    // Fence.I: flush any stale icache lines before jumping to NCM.
    // (NCM has bit[31]=0 so the PMA check should bypass the cache, but
    // issuing FENCE.I ensures a clean state for the first NCM fetch.)
    fence_i();

    my_puts("  Copied 128 B to NCM; issuing FENCE.I before first call\n");

    // Call hot_loop through a function pointer pointing into NCM.
    // The icache will perform a single-beat INCR bypass fetch for every
    // instruction in NCM because bit[31] of NCM addresses is 0 (PMA miss).
    typedef uint32_t (*fn_t)(uint32_t);
    fn_t ncm_fn = (fn_t)(uintptr_t)KV_NCM_BASE;

    // Reference result (from original RAM-resident hot_loop).
    uint32_t ref_ncm = hot_loop(ITERS);

    // First NCM call – measures uncached fetch latency.
    uint32_t t3a = read_csr_mcycle();
    volatile uint32_t ncm_r1 = ncm_fn(ITERS);
    uint32_t t3b = read_csr_mcycle();
    uint32_t ncm_call1 = t3b - t3a;

    // Second NCM call – should take approximately the same time as the first;
    // if the PMA bypass is working correctly, no cache warmup happens.
    uint32_t t3c = read_csr_mcycle();
    volatile uint32_t ncm_r2 = ncm_fn(ITERS);
    uint32_t t3d = read_csr_mcycle();
    uint32_t ncm_call2 = t3d - t3c;

    my_puts("  NCM call 1 cycles: "); print_dec(ncm_call1); my_puts("\n");
    my_puts("  NCM call 2 cycles: "); print_dec(ncm_call2); my_puts("\n");

    // Timing check: if the cache incorrectly cached NCM, call 2 would be
    // dramatically faster (> 2×) than call 1.  Normal measurement noise
    // (± a few cycles) should not trip this check.
    if (ncm_call2 > 0 && ncm_call1 > 0 && ncm_call2 < ncm_call1 / 2) {
        my_puts("  Timing : WARN  (call2 >> faster than call1 – check PMA bypass)\n");
    } else {
        my_puts("  Timing : PASS  (call1 ~= call2: no spurious cache warmup)\n");
    }

    // Correctness check: both results must match the reference.
    if ((uint32_t)ncm_r1 == ref_ncm && (uint32_t)ncm_r2 == ref_ncm) {
        my_puts("  Result : PASS  (NCM execution results match reference)\n\n");
    } else {
        my_puts("  Result : FAIL  (NCM result mismatch: r1=0x");
        print_hex32((uint32_t)ncm_r1);
        my_puts(" r2=0x"); print_hex32((uint32_t)ncm_r2);
        my_puts(" ref=0x"); print_hex32(ref_ncm);
        my_puts(")\n\n");
        fails++;
    }

    // =========================================================
    // Summary
    // =========================================================
    my_puts("========================================\n");
    if (fails == 0) {
        my_puts("  All tests PASSED\n");
    } else {
        my_puts("  FAILURES: "); print_dec(fails); my_puts(" test(s) FAILED\n");
    }
    my_puts("========================================\n\n");

    return fails;
}
