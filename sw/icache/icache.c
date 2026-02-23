// ============================================================================
// File: sw/icache/icache.c
// Project: RV32 RISC-V Processor
// Description: I-Cache functional test
//
// Tests:
//   1. Cold vs warm timing – cache misses on first run, hits on re-run
//   2. FENCE.I instruction  – full cache flush; next run cold again
//   3. cbo.inval instruction – line-level I-cache invalidation (Zicbom)
//   4. MMIO CMO_DISABLE     – bypass mode via axi_magic
//   5. MMIO CMO_ENABLE      – re-enable cache via axi_magic
//   6. MMIO CMO_FLUSH_ALL   – full flush via axi_magic (op=3)
//
// The test runs with ICACHE_EN=0 as well: timing differences will be
// absent, but the instructions must still execute without exceptions.
// ============================================================================

#include <stdint.h>
#include <csr.h>

// ---------------------------------------------------------------------------
// Magic MMIO addresses (axi_magic peripheral, base 0xFFFF0000)
// ---------------------------------------------------------------------------
#define MAGIC_EXIT_ADDR     ((volatile uint32_t *)0xFFFFFFF0U)  // write 0=pass,1=fail
#define MAGIC_CMO_ADDR_REG  ((volatile uint32_t *)0xFFFFFFFCU)  // write: CMO target
#define MAGIC_CMO_CMD_REG   ((volatile uint32_t *)0xFFFFFFF8U)  // write: op; read: idle

// CMO op codes (must match rv32_icache.sv / axi_magic.sv)
#define CMO_OP_INVAL        0x0U   // Invalidate specific cache line
#define CMO_OP_DISABLE      0x1U   // Disable cache (bypass mode)
#define CMO_OP_ENABLE       0x2U   // Enable cache
#define CMO_OP_FLUSH_ALL    0x3U   // Flush / invalidate all lines (= FENCE.I)

// ---------------------------------------------------------------------------
// Helper: output one character via UART MMIO (re-implemented inline to
// avoid pulling in printf complexity).
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
// MMIO CMO helpers
// ---------------------------------------------------------------------------
static void mmio_cmo_wait_idle(void) {
    while ((*MAGIC_CMO_CMD_REG & 1U) == 0U)  // bit-0: 1=idle
        ;
}

static void mmio_cmo_issue(uint32_t op, uint32_t addr) {
    *MAGIC_CMO_ADDR_REG = addr;
    *MAGIC_CMO_CMD_REG  = op;
    mmio_cmo_wait_idle();
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
    // Any unexpected exception: print details and halt
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

    my_puts("\n");
    my_puts("========================================\n");
    my_puts("  I-Cache Functional Test\n");
    my_puts("========================================\n\n");

    // =========================================================
    // TEST 1: Cold vs warm timing
    // =========================================================
    my_puts("[TEST 1] Cold vs warm timing\n");

    // First invalidate the cache so the hot_loop region is cold.
    fence_i();

    uint32_t cold_cycles = time_hot_loop(ITERS);
    uint32_t warm_cycles = time_hot_loop(ITERS);

    my_puts("  Cold cycles: "); print_dec(cold_cycles); my_puts("\n");
    my_puts("  Warm cycles: "); print_dec(warm_cycles); my_puts("\n");

    // With icache enabled, warm must be <= cold.
    // Without icache (ICACHE_EN=0) both will be similar.
    if (warm_cycles <= cold_cycles) {
        my_puts("  Result: PASS  (warm <= cold)\n\n");
    } else {
        my_puts("  WARNING: warm > cold (may be OK if ICACHE_EN=0)\n\n");
        // Don't count as a hard fail; timing depends on memory model
    }

    // =========================================================
    // TEST 2: FENCE.I instruction
    // =========================================================
    my_puts("[TEST 2] FENCE.I instruction\n");

    // Warm the cache
    uint32_t pre_fence_cycles = time_hot_loop(ITERS);

    // Flush the cache with FENCE.I
    fence_i();

    // First run after flush should be slower (cold misses)
    uint32_t post_fence_cycles = time_hot_loop(ITERS);

    my_puts("  Pre-fence  cycles: "); print_dec(pre_fence_cycles);  my_puts("\n");
    my_puts("  Post-fence cycles: "); print_dec(post_fence_cycles); my_puts("\n");

    // After fence.i, second warm run should recover
    uint32_t re_warm_cycles = time_hot_loop(ITERS);
    my_puts("  Re-warm    cycles: "); print_dec(re_warm_cycles); my_puts("\n");

    // Correctness: hot_loop must return the same value every time
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

    // Execute hot_loop – may incur a cache miss on the invalidated line
    uint32_t post_cbo_cycles = time_hot_loop(ITERS);
    my_puts("  Post-cbo.inval cycles: "); print_dec(post_cbo_cycles); my_puts("\n");

    // Correctness: result must still match
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
    // TEST 4: MMIO CMO_DISABLE (bypass mode)
    // =========================================================
    my_puts("[TEST 4] MMIO CMO_DISABLE\n");

    // Warm the cache
    uint32_t before_disable = time_hot_loop(ITERS);

    // Disable the cache via MMIO
    mmio_cmo_issue(CMO_OP_DISABLE, 0U);
    my_puts("  Cache disabled via MMIO\n");

    uint32_t disabled_cycles = time_hot_loop(ITERS);
    my_puts("  Before disable cycles: "); print_dec(before_disable);  my_puts("\n");
    my_puts("  Cache-off    cycles:   "); print_dec(disabled_cycles); my_puts("\n");

    // Correctness: result must still match
    uint32_t ref3 = hot_loop(ITERS);
    if (ref3 == ref) {
        my_puts("  Result: PASS  (hot_loop correct with cache disabled)\n\n");
    } else {
        my_puts("  Result: FAIL  (hot_loop incorrect with cache disabled!)\n\n");
        fails++;
    }

    // =========================================================
    // TEST 5: MMIO CMO_ENABLE (re-enable cache)
    // =========================================================
    my_puts("[TEST 5] MMIO CMO_ENABLE\n");

    mmio_cmo_issue(CMO_OP_ENABLE, 0U);
    my_puts("  Cache re-enabled via MMIO\n");

    // Allow cache to warm up
    (void)hot_loop(ITERS);
    uint32_t re_enabled_cycles = time_hot_loop(ITERS);
    my_puts("  Re-enabled warm cycles: "); print_dec(re_enabled_cycles); my_puts("\n");

    uint32_t ref4 = hot_loop(ITERS);
    if (ref4 == ref) {
        my_puts("  Result: PASS  (hot_loop correct after cache re-enable)\n\n");
    } else {
        my_puts("  Result: FAIL  (hot_loop incorrect after cache re-enable!)\n\n");
        fails++;
    }

    // =========================================================
    // TEST 6: MMIO CMO_FLUSH_ALL (full flush via magic)
    // =========================================================
    my_puts("[TEST 6] MMIO CMO_FLUSH_ALL\n");

    // Warm
    (void)hot_loop(ITERS);

    // Flush all via MMIO (same effect as FENCE.I from software side)
    mmio_cmo_issue(CMO_OP_FLUSH_ALL, 0U);
    my_puts("  Issued MMIO CMO_FLUSH_ALL\n");

    uint32_t post_flush_cycles = time_hot_loop(ITERS);
    my_puts("  Post-MMIO-flush cycles: "); print_dec(post_flush_cycles); my_puts("\n");

    uint32_t ref5 = hot_loop(ITERS);
    if (ref5 == ref) {
        my_puts("  Result: PASS  (hot_loop correct after MMIO flush-all)\n\n");
    } else {
        my_puts("  Result: FAIL  (hot_loop incorrect after MMIO flush-all!)\n\n");
        fails++;
    }

    // =========================================================
    // Test 7: MMIO CMO_INVAL (line-level via magic)
    // =========================================================
    my_puts("[TEST 7] MMIO CMO_INVAL\n");

    // Warm the cache
    (void)hot_loop(ITERS);

    // Invalidate one line via MMIO
    mmio_cmo_issue(CMO_OP_INVAL, (uint32_t)(uintptr_t)&hot_loop);
    my_puts("  Issued MMIO CMO_INVAL for hot_loop @ 0x");
    print_hex32((uint32_t)(uintptr_t)&hot_loop);
    my_puts("\n");

    uint32_t ref6 = hot_loop(ITERS);
    if (ref6 == ref) {
        my_puts("  Result: PASS  (hot_loop correct after MMIO line inval)\n\n");
    } else {
        my_puts("  Result: FAIL  (hot_loop incorrect after MMIO line inval!)\n\n");
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
