// ============================================================================
// File: cache_diag.c
// Project: KV32 RISC-V Processor
// Description: Cache diagnostic CSR test + cache dump utility.
// ============================================================================

#include <stdint.h>
#include <stdio.h>

#include "csr.h"
#include "kv_cache.h"
#include "kv_cap.h"
#include "kv_pma.h"
#include "kv_platform.h"

#define N 100

static int g_pass;
static int g_fail;

static inline uint32_t read_csr_icap(void)
{
    uint32_t v;
    __asm__ volatile ("csrr %0, 0x7D0" : "=r"(v));
    return v;
}

static inline uint32_t read_csr_dcap(void)
{
    uint32_t v;
    __asm__ volatile ("csrr %0, 0x7D1" : "=r"(v));
    return v;
}

static void quicksort_i32(int32_t *a, int lo, int hi)
{
    int i;
    int j;
    int32_t pivot;

    if (lo >= hi) {
        return;
    }

    i = lo;
    j = hi;
    pivot = a[(lo + hi) >> 1];

    while (i <= j) {
        while (a[i] < pivot) {
            i++;
        }
        while (a[j] > pivot) {
            j--;
        }
        if (i <= j) {
            int32_t t = a[i];
            a[i] = a[j];
            a[j] = t;
            i++;
            j--;
        }
    }

    if (lo < j) {
        quicksort_i32(a, lo, j);
    }
    if (i < hi) {
        quicksort_i32(a, i, hi);
    }
}

void kv_icache_dump(void)
{
    uint32_t cap = read_csr_icap();
    uint32_t ways = KV_CAP_WAYS(cap);
    uint32_t sets = KV_CAP_SETS(cap);
    uint32_t wpl  = KV_CAP_WPL(cap);

    for (uint32_t set = 0; set < sets; set++) {
        for (uint32_t way = 0; way < ways; way++) {
            uint32_t cmd = KV_CDIAG_CMD(KV_CDIAG_CMD_ICACHE, way, set, 0);
            uint32_t tag_word = kv_cdiag_tag(cmd);
            printf("[I$] set=%2u way=%u V=%u tag=0x%06x data:",
                     (unsigned)set, (unsigned)way,
                   (unsigned)KV_CDIAG_VALID(tag_word),
                   (unsigned)KV_CDIAG_TAG(tag_word));

            for (uint32_t word = 0; word < wpl; word++) {
                cmd = KV_CDIAG_CMD(KV_CDIAG_CMD_ICACHE, way, set, word);
                printf(" %08x", (unsigned)kv_cdiag_data(cmd));
            }
            printf("\n");
        }
    }
}

void kv_dcache_dump(void)
{
    uint32_t cap = read_csr_dcap();
    uint32_t ways = KV_CAP_WAYS(cap);
    uint32_t sets = KV_CAP_SETS(cap);
    uint32_t wpl  = KV_CAP_WPL(cap);

    for (uint32_t set = 0; set < sets; set++) {
        for (uint32_t way = 0; way < ways; way++) {
            uint32_t cmd = KV_CDIAG_CMD(KV_CDIAG_CMD_DCACHE, way, set, 0);
            uint32_t tag_word = kv_cdiag_tag(cmd);
            printf("[D$] set=%2u way=%u D=%u V=%u tag=0x%06x data:",
                     (unsigned)set, (unsigned)way,
                   (unsigned)KV_CDIAG_DIRTY(tag_word),
                   (unsigned)KV_CDIAG_VALID(tag_word),
                   (unsigned)KV_CDIAG_TAG(tag_word));

            for (uint32_t word = 0; word < wpl; word++) {
                cmd = KV_CDIAG_CMD(KV_CDIAG_CMD_DCACHE, way, set, word);
                printf(" %08x", (unsigned)kv_cdiag_data(cmd));
            }
            printf("\n");
        }
    }
}

void kv_cache_dump(void)
{
    kv_icache_dump();
    kv_dcache_dump();
}

int main(void)
{
    uint32_t icap;
    uint32_t dcap;

    printf("\n=== Cache Diagnostic CSR Test ===\n");

    printf("[TEST 1] CSR geometry\n");
    icap = read_csr_icap();
    dcap = read_csr_dcap();
    if ((icap == KV_CAP_ICAP_VALUE) && (dcap == KV_CAP_DCAP_VALUE)) {
        printf("[TEST 1] PASS\n");
        g_pass++;
    } else {
        printf("[TEST 1] FAIL: icap=0x%08x dcap=0x%08x\n", (unsigned)icap, (unsigned)dcap);
        g_fail++;
    }

    printf("[TEST 2] Quicksort workload\n");
    {
        int32_t data[N];
        uint32_t seed = 12345u;
        uint32_t t0;
        uint32_t cycles;
        uint32_t checksum = 0;
        int sorted = 1;

        for (int i = 0; i < N; i++) {
            seed = seed * 1103515245u + 12345u;
            data[i] = (int32_t)(seed & 0x7FFFFFFFu);
        }

        t0 = read_csr_mcycle();
        quicksort_i32(data, 0, N - 1);
        cycles = read_csr_mcycle() - t0;

        for (int i = 1; i < N; i++) {
            if (data[i - 1] > data[i]) {
                sorted = 0;
                break;
            }
        }
        for (int i = 0; i < N; i++) {
            checksum += (uint32_t)data[i];
        }

        if (sorted) {
            printf("[TEST 2] PASS: cycles=%u checksum=0x%08x\n", (unsigned)cycles, (unsigned)checksum);
            g_pass++;
        } else {
            printf("[TEST 2] FAIL: array not sorted\n");
            g_fail++;
        }
    }

    printf("[TEST 3] Cache state after qsort\n");
    kv_pma_set_napot(0, KV_RAM_BASE, KV_RAM_SIZE,
                     KV_PMA_DCACHEABLE | KV_PMA_BUFFERABLE);
    kv_fence_i();
    kv_cache_dump();
    kv_pma_set_napot(0, KV_RAM_BASE, KV_RAM_SIZE,
                     KV_PMA_ICACHEABLE | KV_PMA_DCACHEABLE | KV_PMA_BUFFERABLE);
    kv_fence_i();
    kv_pma_clear_region(0);
    printf("[TEST 3] Done\n");

    printf("Summary: PASS=%d FAIL=%d\n", g_pass, g_fail);
    return g_fail;
}
