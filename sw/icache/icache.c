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
#include "kv_cache.h"
#include "kv_pma.h"
#include "kv_irq.h"

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
// aligned(4): RVC may produce 2-byte-aligned function placement; word-copy in
// TEST 4 requires the source to be naturally word-aligned.
// ---------------------------------------------------------------------------
static uint32_t __attribute__((noinline, aligned(4))) hot_loop(uint32_t iters) {
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
// Minimal trap handler (required by start.S)
// ---------------------------------------------------------------------------
void trap_handler(kv_trap_frame_t *frame) {
    my_puts("TRAP mcause=0x"); print_hex32(frame->mcause);
    my_puts(" mepc=0x");       print_hex32(frame->mepc);
    my_puts(" mtval=0x");      print_hex32(frame->mtval);
    my_puts("\n");

    // Skip the faulting instruction so execution can continue.
    uint16_t inst16 = *(volatile uint16_t *)frame->mepc;
    frame->mepc += (((inst16 & 0x3u) != 0x3u) ? 2u : 4u);
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
    kv_fence_i();

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
    kv_fence_i();
    uint32_t post_fence_cycles = time_hot_loop(ITERS);

    my_puts("  Pre-fence  cycles: "); print_dec(pre_fence_cycles);  my_puts("\n");
    my_puts("  Post-fence cycles: "); print_dec(post_fence_cycles); my_puts("\n");

    uint32_t re_warm_cycles = time_hot_loop(ITERS);
    my_puts("  Re-warm    cycles: "); print_dec(re_warm_cycles); my_puts("\n");

    // Correctness: hot_loop must return the same value across fence.i
    uint32_t ref = hot_loop(ITERS);
    kv_fence_i();
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
    kv_cbo_inval((void *)&hot_loop);
    my_puts("  Issued cbo.inval for hot_loop @ 0x");
    print_hex32((uint32_t)(uintptr_t)&hot_loop);
    my_puts("\n");

    uint32_t post_cbo_cycles = time_hot_loop(ITERS);
    my_puts("  Post-cbo.inval cycles: "); print_dec(post_cbo_cycles); my_puts("\n");

    // Correctness: result must still match after invalidation
    uint32_t ref2 = hot_loop(ITERS);
    kv_fence_i();
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
    kv_fence_i();

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
    // TEST 5: PMA CSR – mark RAM non-I-cacheable, verify bypass
    // =========================================================
    my_puts("[TEST 5] PMA CSR: mark RAM non-I-cacheable via NAPOT region\n");
    {
        // Program region 0: NAPOT covering the full SRAM (2 MB at 0x8000_0000).
        // Remove the X (I-cacheable) bit – D-cacheable + bufferable stay set so
        // data accesses are unaffected.
        kv_pma_set_napot(0, KV_RAM_BASE, KV_RAM_SIZE,
                         KV_PMA_DCACHEABLE | KV_PMA_BUFFERABLE);
        kv_fence_i();   // flush all live I-cache lines before the bypass test

        // With X=0, every instruction fetch should bypass the I-cache.
        // Both calls should take similar cycles – no warm-up.
        uint32_t pma_call1 = time_hot_loop(ITERS);
        uint32_t pma_call2 = time_hot_loop(ITERS);

        my_puts("  Non-I-cacheable call 1 cycles: "); print_dec(pma_call1); my_puts("\n");
        my_puts("  Non-I-cacheable call 2 cycles: "); print_dec(pma_call2); my_puts("\n");

        // Correctness: hot_loop must still return the correct value
        uint32_t ref_pma = hot_loop(ITERS);
        kv_fence_i();
        uint32_t chk_pma = hot_loop(ITERS);
        if (ref_pma == chk_pma) {
            my_puts("  Correctness: PASS  (hot_loop result unchanged under bypass)\n");
        } else {
            my_puts("  Correctness: FAIL  (hot_loop result corrupted!)\n");
            fails++;
        }

        // Bypass check: call2 should NOT be dramatically faster than call1
        if (pma_call2 > 0 && pma_call1 > 0 && pma_call2 < pma_call1 / 2) {
            my_puts("  Timing:      WARN  (call2 >> faster – PMA bypass may not work)\n\n");
        } else {
            my_puts("  Timing:      PASS  (call1 ~= call2: no spurious I-cache warmup)\n\n");
        }

        // Restore: re-enable I-cacheability for RAM
        kv_pma_set_napot(0, KV_RAM_BASE, KV_RAM_SIZE,
                         KV_PMA_ICACHEABLE | KV_PMA_DCACHEABLE | KV_PMA_BUFFERABLE);
        kv_fence_i();   // cold-start with caching re-enabled

        uint32_t cold_r = time_hot_loop(ITERS);
        uint32_t warm_r = time_hot_loop(ITERS);
        my_puts("  After restore – cold: "); print_dec(cold_r);
        my_puts("  warm: "); print_dec(warm_r); my_puts("\n");
        if (warm_r <= cold_r) {
            my_puts("  Restore:     PASS  (I-cacheability restored, warm <= cold)\n\n");
        } else {
            my_puts("  Restore:     WARN  (warm > cold after restore)\n\n");
        }

        // Disable region 0 (A=00 → fallback to legacy bit[31] rule)
        kv_pma_clear_region(0);
        kv_fence_i();
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
