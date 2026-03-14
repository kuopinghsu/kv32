// ============================================================================
// File: cachebench.c
// Project: KV32 RISC-V Processor
// Description: University of Tennessee CacheBench (LLCBENCH) adapted for
//              KV32 bare-metal.  Measures memory system bandwidth (MB/s) for
//              sequential read, write, and read-modify-write (RMW) operations
//              at dataset sizes spanning the full cache hierarchy — from
//              working-set fits-in-L1 up to DRAM-resident.
//
//  Output (one row per size × operation):
//    <size> <op>: <cycles> cycles  <mbps> MB/s
//
//  Reference: M. Farrens & A. LaMarca, "An evaluation of memory system
//             performance for vector and scalar processors" — UT ICL
//             LLCBench / CacheBench methodology.
// ============================================================================

#include <stdint.h>
#include <csr.h>
#include "kv_platform.h"
#include "kv_irq.h"

// ---------------------------------------------------------------------------
// Platform: system clock frequency used for MB/s computation.
// Override via -DSYS_CLK_HZ=<N> if the target clock differs.
// ---------------------------------------------------------------------------
#ifndef SYS_CLK_HZ
#define SYS_CLK_HZ  100000000UL   /* 100 MHz — KV32 simulation default */
#endif

// ---------------------------------------------------------------------------
// Test buffer: maximum dataset = 128 KB (32768 × 4-byte words).
// Aligned to a cache-line boundary (32 B) so the first access of each sweep
// starts at a predictable offset within the cache.
// ---------------------------------------------------------------------------
#define MAX_WORDS  32768U

static volatile uint32_t buf[MAX_WORDS] __attribute__((aligned(32)));

// ---------------------------------------------------------------------------
// Minimal I/O helpers (same pattern as dcache.c / icache.c)
// ---------------------------------------------------------------------------
extern void putc(char c);

static void my_puts(const char *s) { while (*s) putc(*s++); }

static void print_dec(uint32_t v) {
    if (v == 0) { putc('0'); return; }
    char b[12]; int n = 0;
    while (v > 0) { b[n++] = '0' + (v % 10); v /= 10; }
    while (n > 0) putc(b[--n]);
}

static void print_hex32(uint32_t v) {
    const char h[] = "0123456789abcdef";
    for (int i = 7; i >= 0; i--) putc(h[(v >> (i * 4)) & 0xf]);
}

// ---------------------------------------------------------------------------
// Minimal trap handler (required by start.S)
// ---------------------------------------------------------------------------
void trap_handler(kv_trap_frame_t *frame) {
    my_puts("TRAP mcause=0x"); print_hex32(frame->mcause);
    my_puts(" mepc=0x");       print_hex32(frame->mepc);
    my_puts(" mtval=0x");      print_hex32(frame->mtval);
    my_puts("\n");
    uint16_t inst16 = *(volatile uint16_t *)frame->mepc;
    frame->mepc += (((inst16 & 0x3u) != 0x3u) ? 2u : 4u);
}

// ---------------------------------------------------------------------------
// Benchmark kernels
// Each returns the elapsed mcycle count for (words × reps) element accesses.
// buf is declared volatile so the compiler cannot eliminate any load/store.
// ---------------------------------------------------------------------------

/* Sequential read: sum all elements to defeat dead-code elimination. */
static uint32_t bench_read(uint32_t words, uint32_t reps)
{
    uint32_t acc = 0;
    uint32_t t0 = read_csr_mcycle();
    for (uint32_t r = 0; r < reps; r++)
        for (uint32_t i = 0; i < words; i++)
            acc += buf[i];
    uint32_t t1 = read_csr_mcycle();
    (void)acc;
    return t1 - t0;
}

/* Sequential write: store a data-dependent value to each element. */
static uint32_t bench_write(uint32_t words, uint32_t reps)
{
    uint32_t t0 = read_csr_mcycle();
    for (uint32_t r = 0; r < reps; r++)
        for (uint32_t i = 0; i < words; i++)
            buf[i] = r ^ i;           /* data-dependent, prevents const folding */
    uint32_t t1 = read_csr_mcycle();
    return t1 - t0;
}

/* Read-modify-write: increment each element in place. */
static uint32_t bench_rmw(uint32_t words, uint32_t reps)
{
    uint32_t t0 = read_csr_mcycle();
    for (uint32_t r = 0; r < reps; r++)
        for (uint32_t i = 0; i < words; i++)
            buf[i] += 1u;
    uint32_t t1 = read_csr_mcycle();
    return t1 - t0;
}

// ---------------------------------------------------------------------------
// Print one result row.
// bandwidth (MB/s) = (bytes_transferred × SYS_CLK_HZ) / (cycles × 1 MiB)
// Uses uint64_t intermediate to avoid 32-bit overflow (same as dma.c).
// ---------------------------------------------------------------------------
static void print_row(const char *size_str, const char *op_str,
                      uint32_t words, uint32_t reps, uint32_t cycles)
{
    my_puts("  ");
    my_puts(size_str);
    my_puts("  ");
    my_puts(op_str);
    my_puts("  ");
    print_dec(cycles);
    my_puts(" cycles  ");

    uint32_t mbps = 0;
    if (cycles > 0) {
        uint64_t bytes = (uint64_t)words * 4U * (uint64_t)reps;
        mbps = (uint32_t)(bytes * (uint64_t)SYS_CLK_HZ
                         / ((uint64_t)cycles * 1048576UL));
    }
    print_dec(mbps);
    my_puts(" MB/s\n");
}

// ---------------------------------------------------------------------------
// Dataset size table.
// words × reps is held roughly constant at ~8192 elements (32 KB) so that
// each timed window lasts a comparable number of cycles regardless of size.
// Sizes above 4096 words (16 KB) use a minimum of 1 rep to bound runtime
// on uncached DRAM paths.
// ---------------------------------------------------------------------------
typedef struct { uint32_t words; uint32_t reps; const char *name; } size_cfg_t;

static const size_cfg_t sizes[] = {
    {   256, 32, "  1KB" },
    {   512, 16, "  2KB" },
    {  1024,  8, "  4KB" },
    {  2048,  4, "  8KB" },
    {  4096,  2, " 16KB" },
    {  8192,  2, " 32KB" },
    { 16384,  1, " 64KB" },
    { 32768,  1, "128KB" },
};
/* CB_NUM_SIZES_LIMIT can be set at compile time (e.g. -DCB_NUM_SIZES_LIMIT=5)
 * to restrict the sweep to the first N dataset sizes.  Useful when running
 * inside cache_benchmark_v2.sh where the largest DDR4-uncached sizes would
 * take impractically long to simulate in RTL. */
#ifdef CB_NUM_SIZES_LIMIT
#  define NUM_SIZES  ((uint32_t)(CB_NUM_SIZES_LIMIT))
#else
#  define NUM_SIZES  (sizeof(sizes) / sizeof(sizes[0]))
#endif

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(void)
{
    my_puts("\n");
    my_puts("========================================\n");
    my_puts("  KV32 CacheBench (UT/LLCBENCH-style)\n");
    my_puts("========================================\n");

#if !defined(DCACHE_EN) || DCACHE_EN == 0
    my_puts("  DCACHE_EN=0  (uncached — latency-bound results expected)\n");
#else
    my_puts("  DCACHE_EN=1  (D-Cache enabled)\n");
#endif

    my_puts("  SYS_CLK=");
    print_dec(SYS_CLK_HZ / 1000000UL);
    my_puts("MHz  buf@0x");
    print_hex32((uint32_t)(uintptr_t)buf);
    my_puts("\n\n");

    my_puts("  Size   Op     Cycles       Bandwidth\n");
    my_puts("  -----  -----  -----------  ---------\n");

    /* Warm up the measurement infrastructure (mcycle read overhead). */
    (void)bench_read(256, 1);

    for (uint32_t s = 0; s < NUM_SIZES; s++) {
        const uint32_t  words = sizes[s].words;
        const uint32_t  reps  = sizes[s].reps;
        const char     *nm    = sizes[s].name;

        /* Initialise the buffer before each size so there are no cold BSS
         * misses on the first measured pass (write-back fills the cache for
         * the subsequent read and RMW tests). */
        bench_write(words, 1);

        /* READ — one untimed warm-up pass, then the timed measurement. */
        (void)bench_read(words, 1);
        uint32_t rc = bench_read(words, reps);
        print_row(nm, "READ ", words, reps, rc);

        /* WRITE */
        uint32_t wc = bench_write(words, reps);
        print_row(nm, "WRITE", words, reps, wc);

        /* READ-MODIFY-WRITE */
        uint32_t mc = bench_rmw(words, reps);
        print_row(nm, "RMW  ", words, reps, mc);
    }

    my_puts("\nCacheBench: DONE\n");
    kv_magic_exit(0);
    return 0;
}
