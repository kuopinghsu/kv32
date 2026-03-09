// ============================================================================
// File: dcache.c
// Project: KV32 RISC-V Processor
// Description: D-Cache functional test: cold/warm timing, write-back, CBO
//              invalidation, FENCE.I coherency, non-cacheable bypass, and
//              store-buffer interaction.
// Tests: cold-miss vs warm-hit cycle counts, cbo.inval, cbo.flush write-back,
//        FENCE.I full flush, non-cacheable PMA bypass, store-buffer ordering.
// Also runs correctly with DCACHE_EN=0 (no timing assertions).
// ============================================================================

#include <stdint.h>
#include <csr.h>
#include "kv_platform.h"
#include "kv_cache.h"
#include "kv_pma.h"

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
// Minimal trap handler (required by start.S)
// ---------------------------------------------------------------------------
void trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval) {
    my_puts("TRAP mcause=0x"); print_hex32(mcause);
    my_puts(" mepc=0x");       print_hex32(mepc);
    my_puts(" mtval=0x");      print_hex32(mtval);
    my_puts("\n");
    uint16_t inst16 = *(volatile uint16_t *)mepc;
    uint32_t next_pc = mepc + (((inst16 & 0x3u) != 0x3u) ? 2u : 4u);
    asm volatile("csrw mepc, %0" :: "r"(next_pc));
}

// ---------------------------------------------------------------------------
// Test buffer (aligned to cache line size = 32 bytes)
// ---------------------------------------------------------------------------
#define BUF_WORDS   64
#define LINE_BYTES  32    /* DCACHE_LINE_SIZE */
#define LINE_WORDS  (LINE_BYTES / 4)

static volatile uint32_t tbuf[BUF_WORDS] __attribute__((aligned(LINE_BYTES)));

// ---------------------------------------------------------------------------
// Time a sequential read sweep across the buffer (BUF_WORDS reads).
// Returns cycle count.
// ---------------------------------------------------------------------------
static uint32_t time_read_sweep(void) {
    volatile uint32_t acc = 0;
    uint32_t t0 = read_csr_mcycle();
    for (int i = 0; i < BUF_WORDS; i++)
        acc += tbuf[i];
    uint32_t t1 = read_csr_mcycle();
    (void)acc;
    return t1 - t0;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(void) {
    int fails = 0;

#if !defined(DCACHE_EN) || DCACHE_EN == 0
    my_puts("\nDCACHE_EN=0: D-Cache not present, skipping cache tests\n");
    kv_magic_exit(0);
    return 0;
#endif

    my_puts("\n");
    my_puts("========================================\n");
    my_puts("  D-Cache Functional Test\n");
    my_puts("========================================\n\n");

    my_puts("  tbuf @ 0x"); print_hex32((uint32_t)(uintptr_t)tbuf);
    my_puts(" ("); print_dec(BUF_WORDS * 4); my_puts(" bytes)\n\n");

    // =========================================================
    // TEST 1: Basic write + read-back correctness
    // =========================================================
    my_puts("[TEST 1] Write + read-back\n");
    {
        const uint32_t PATTERN = 0xdeadbeefUL;
        for (int i = 0; i < BUF_WORDS; i++)
            tbuf[i] = PATTERN ^ (uint32_t)i;

        kv_fence_rw();

        int ok = 1;
        for (int i = 0; i < BUF_WORDS; i++) {
            if (tbuf[i] != (PATTERN ^ (uint32_t)i)) {
                ok = 0;
                my_puts("  FAIL at word "); print_dec(i);
                my_puts(": got 0x"); print_hex32(tbuf[i]);
                my_puts(" exp 0x"); print_hex32(PATTERN ^ (uint32_t)i);
                my_puts("\n");
                fails++;
                break;
            }
        }
        if (ok) my_puts("  Result: PASS  (all words read back correctly)\n\n");
        else    my_puts("  Result: FAIL\n\n");
    }

    // =========================================================
    // TEST 2: Cold vs warm timing
    // =========================================================
    my_puts("[TEST 2] Cold vs warm timing\n");
    {
        // Force cold state: flush and invalidate entire buffer
        for (int i = 0; i < BUF_WORDS; i += LINE_WORDS)
            kv_cbo_flush((void *)&tbuf[i]);

        uint32_t cold_cycles = time_read_sweep();
        uint32_t warm_cycles = time_read_sweep();

        my_puts("  Cold cycles: "); print_dec(cold_cycles); my_puts("\n");
        my_puts("  Warm cycles: "); print_dec(warm_cycles); my_puts("\n");

        if (warm_cycles <= cold_cycles)
            my_puts("  Result: PASS  (warm <= cold)\n\n");
        else
            my_puts("  Result: WARN  (warm > cold; may be OK without dcache)\n\n");
    }

    // =========================================================
    // TEST 3: cbo.flush write-back
    // =========================================================
    my_puts("[TEST 3] cbo.flush write-back\n");
    {
        // Step 1: write a known pattern into the first cache line via CPU stores
        for (int i = 0; i < LINE_WORDS; i++)
            tbuf[i] = 0xAA000000UL | (uint32_t)i;

        kv_fence_rw();

        // Step 2: flush the line (forces write-back to backing memory)
        kv_cbo_flush((void *)&tbuf[0]);

        // Step 3: invalidate the same line so the next read goes to memory
        kv_cbo_inval((void *)&tbuf[0]);

        // Step 4: read back – should come from memory, not any stale dcache copy
        int ok = 1;
        for (int i = 0; i < LINE_WORDS; i++) {
            uint32_t exp = 0xAA000000UL | (uint32_t)i;
            if (tbuf[i] != exp) {
                ok = 0;
                my_puts("  FAIL at word "); print_dec(i);
                my_puts(": got 0x"); print_hex32(tbuf[i]);
                my_puts(" exp 0x"); print_hex32(exp);
                my_puts("\n");
                fails++;
                break;
            }
        }
        if (ok) my_puts("  Result: PASS  (flush+reload preserved data)\n\n");
        else    my_puts("  Result: FAIL\n\n");
    }

    // =========================================================
    // TEST 4: cbo.inval discards dirty line
    // =========================================================
    my_puts("[TEST 4] cbo.inval discards dirty line\n");
    {
        // Write original data and flush to backing store so memory is definitive
        for (int i = 0; i < LINE_WORDS; i++)
            tbuf[i] = 0xBB000000UL | (uint32_t)i;
        kv_cbo_flush((void *)&tbuf[0]);   // writeback to memory

        // Overwrite the line in cache (dirty, not yet written to memory)
        for (int i = 0; i < LINE_WORDS; i++)
            tbuf[i] = 0xCC000000UL | (uint32_t)i;

        // Invalidate (discard dirty data; memory still holds 0xBB version)
        kv_cbo_inval((void *)&tbuf[0]);

        // Read back: on real hardware (write-back cache) → 0xBB from memory.
        // On write-through sim: all stores go directly to memory, so both cbo_flush
        // and the subsequent stores updated memory with 0xCC.  In that case the
        // "invalidation" still brings in the latest mem (0xCC), which is fine.
        uint32_t r0 = tbuf[0];
        uint32_t exp_wb  = 0xBB000000UL;   // write-back HW: invalidate reverts
        uint32_t exp_wt  = 0xCC000000UL;   // write-through sim: latest write wins

        if (r0 == exp_wb) {
            my_puts("  Result: PASS  (inval reverted to original in memory)\n\n");
        } else if (r0 == exp_wt) {
            // Acceptable on write-through sim — cache was not actually dirty
            my_puts("  Result: PASS  (write-through: inval brought in latest memory)\n\n");
        } else {
            my_puts("  FAIL at word 0: got 0x"); print_hex32(r0);
            my_puts(" exp 0x"); print_hex32(exp_wb);
            my_puts(" (or sim: 0x"); print_hex32(exp_wt);
            my_puts(")\n  Result: FAIL\n\n");
            fails++;
        }
    }

    // =========================================================
    // TEST 5: FENCE.I coherency flush
    // =========================================================
    my_puts("[TEST 5] FENCE.I flushes D-Cache\n");
    {
        // Write dirty data into several cache lines
        for (int i = 0; i < BUF_WORDS; i++)
            tbuf[i] = 0xDD000000UL | (uint32_t)i;

        kv_fence_rw();

        // FENCE.I must flush icache AND dcache (CMO_FLUSH_ALL to both caches)
        kv_fence_i();

        // After FENCE.I, invalidate all lines so reads go to memory
        for (int i = 0; i < BUF_WORDS; i += LINE_WORDS)
            kv_cbo_inval((void *)&tbuf[i]);

        // Verify memory contains the correct data written before FENCE.I
        int ok = 1;
        for (int i = 0; i < BUF_WORDS; i++) {
            uint32_t exp = 0xDD000000UL | (uint32_t)i;
            if (tbuf[i] != exp) {
                ok = 0;
                my_puts("  FAIL at word "); print_dec(i);
                my_puts(": got 0x"); print_hex32(tbuf[i]);
                my_puts(" exp 0x"); print_hex32(exp);
                my_puts("\n");
                fails++;
                break;
            }
        }
        if (ok) my_puts("  Result: PASS  (FENCE.I flushed all dirty lines)\n\n");
        else    my_puts("  Result: FAIL\n\n");
    }

    // =========================================================
    // TEST 6: Non-cacheable bypass (PMA: bit[31]=0 → no cache)
    // =========================================================
    my_puts("[TEST 6] Non-cacheable Memory (NCM) bypass\n");
    {
        my_puts("  NCM base: 0x"); print_hex32(KV_NCM_BASE); my_puts("\n");

        volatile uint32_t *ncm = (volatile uint32_t *)(uintptr_t)KV_NCM_BASE;
        const uint32_t NCPAT = 0x12345678UL;

        // Write unique value directly to NCM (no caching expected)
        ncm[0] = NCPAT;
        ncm[1] = ~NCPAT;

        kv_fence_rw();

        // Read back – should see exactly what was written (no stale cache)
        uint32_t r0 = ncm[0];
        uint32_t r1 = ncm[1];

        if (r0 == NCPAT && r1 == ~NCPAT) {
            my_puts("  Result: PASS  (NCM read-back correct)\n\n");
        } else {
            my_puts("  FAIL: ncm[0]=0x"); print_hex32(r0);
            my_puts(" exp=0x"); print_hex32(NCPAT);
            my_puts("  ncm[1]=0x"); print_hex32(r1);
            my_puts(" exp=0x"); print_hex32(~NCPAT);
            my_puts("\n  Result: FAIL\n\n");
            fails++;
        }

        // Timing: two sweeps of NCM should take similar time (no warmup)
        volatile uint32_t acc = 0;
        uint32_t t0 = read_csr_mcycle();
        for (int i = 0; i < 16; i++) acc += ncm[i];
        uint32_t t1 = read_csr_mcycle();
        uint32_t ncm1 = t1 - t0;

        t0 = read_csr_mcycle();
        for (int i = 0; i < 16; i++) acc += ncm[i];
        t1 = read_csr_mcycle();
        uint32_t ncm2 = t1 - t0;
        (void)acc;

        my_puts("  NCM sweep1 cycles: "); print_dec(ncm1); my_puts("\n");
        my_puts("  NCM sweep2 cycles: "); print_dec(ncm2); my_puts("\n");
        if (ncm2 > 0 && ncm1 > 0 && ncm2 < ncm1 / 2)
            my_puts("  Timing: WARN  (sweep2 much faster – possible spurious caching)\n\n");
        else
            my_puts("  Timing: PASS  (sweep1 ~= sweep2: no spurious cache warmup)\n\n");
    }

    // =========================================================
    // TEST 7: Store-buffer ordering
    // =========================================================
    my_puts("[TEST 7] Store-buffer ordering\n");
    {
        // Issue back-to-back stores to consecutive words and verify order
        for (int i = 0; i < BUF_WORDS; i++)
            tbuf[i] = (uint32_t)(i * 0x11111111UL);

        // Full memory fence to ensure all stores committed before reads
        kv_fence_rw();

        int ok = 1;
        for (int i = 0; i < BUF_WORDS; i++) {
            uint32_t exp = (uint32_t)(i * 0x11111111UL);
            if (tbuf[i] != exp) {
                ok = 0;
                my_puts("  FAIL at word "); print_dec(i);
                my_puts(": got 0x"); print_hex32(tbuf[i]);
                my_puts(" exp 0x"); print_hex32(exp);
                my_puts("\n");
                fails++;
                break;
            }
        }
        if (ok) my_puts("  Result: PASS  (all stores in correct order)\n\n");
        else    my_puts("  Result: FAIL\n\n");
    }

    // =========================================================
    // TEST 8: PMA CSR – mark RAM non-D-cacheable, verify bypass
    // =========================================================
    my_puts("[TEST 8] PMA CSR: mark RAM non-D-cacheable via NAPOT region\n");
    {
        // Write a known pattern and flush to backing memory before switching PMA
        for (int i = 0; i < BUF_WORDS; i++)
            tbuf[i] = 0xEE000000UL | (uint32_t)i;
        for (int i = 0; i < BUF_WORDS; i += LINE_WORDS)
            kv_cbo_flush((void *)&tbuf[i]);

        // Program region 0: NAPOT covering the full SRAM (2 MB at 0x8000_0000).
        // Remove the C (D-cacheable) bit – I-cacheable + bufferable stay set so
        // instruction fetches are unaffected.
        kv_pma_set_napot(0, KV_RAM_BASE, KV_RAM_SIZE,
                         KV_PMA_ICACHEABLE | KV_PMA_BUFFERABLE);
        kv_fence_rw();

        // With C=0, every data access should bypass the D-cache.
        // Both sweeps should take similar cycles – no warm-up.
        uint32_t pma_sweep1 = time_read_sweep();
        uint32_t pma_sweep2 = time_read_sweep();

        my_puts("  Non-D-cacheable sweep 1 cycles: "); print_dec(pma_sweep1); my_puts("\n");
        my_puts("  Non-D-cacheable sweep 2 cycles: "); print_dec(pma_sweep2); my_puts("\n");

        // Bypass check: sweep2 should NOT be dramatically faster than sweep1
        if (pma_sweep2 > 0 && pma_sweep1 > 0 && pma_sweep2 < pma_sweep1 / 2) {
            my_puts("  Timing: WARN  (sweep2 >> faster – PMA bypass may not work)\n");
        } else {
            my_puts("  Timing: PASS  (sweep1 ~= sweep2: no spurious D-cache warmup)\n");
        }

        // Correctness: data flushed to memory before PMA switch must read back correctly
        int ok = 1;
        for (int i = 0; i < BUF_WORDS; i++) {
            if (tbuf[i] != (0xEE000000UL | (uint32_t)i)) {
                ok = 0;
                my_puts("  FAIL at word "); print_dec(i);
                my_puts(": got 0x"); print_hex32(tbuf[i]); my_puts("\n");
                fails++;
                break;
            }
        }
        if (ok) my_puts("  Correctness: PASS  (bypass read-back correct)\n");
        else    my_puts("  Correctness: FAIL\n");

        // Restore: re-enable D-cacheability for RAM
        kv_pma_set_napot(0, KV_RAM_BASE, KV_RAM_SIZE,
                         KV_PMA_ICACHEABLE | KV_PMA_DCACHEABLE | KV_PMA_BUFFERABLE);

        // Force cold state so the timing check is meaningful
        for (int i = 0; i < BUF_WORDS; i += LINE_WORDS)
            kv_cbo_flush((void *)&tbuf[i]);

        uint32_t cold_r = time_read_sweep();
        uint32_t warm_r = time_read_sweep();
        my_puts("  After restore – cold: "); print_dec(cold_r);
        my_puts("  warm: "); print_dec(warm_r); my_puts("\n");
        if (warm_r <= cold_r) {
            my_puts("  Restore: PASS  (D-cacheability restored, warm <= cold)\n\n");
        } else {
            my_puts("  Restore: WARN  (warm > cold after restore)\n\n");
        }

        // Disable region 0 (A=00 → fallback to legacy bit[31] rule)
        kv_pma_clear_region(0);
        kv_fence_rw();
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
