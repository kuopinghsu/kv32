// ============================================================================
// File: stack_guard.c
// Project: KV32 RISC-V Processor
// Description: Standalone test for SGUARD_BASE/SPMIN custom CSRs
// ============================================================================

#include <stdint.h>
#include <stdio.h>
#include "kv_platform.h"
#include "kv_irq.h"
#include "kv_wdt.h"
#include "csr.h"

static volatile int g_pass = 0;
static volatile int g_fail = 0;
static volatile int g_overflow_seen = 0;
static volatile uint32_t g_last_mcause = 0;
static volatile uint32_t g_last_mtval = 0;
static volatile uint32_t g_expected_bad_sp = 0;

static inline void test_pass(const char *name)
{
    printf("[PASS] %s\n", name);
    g_pass++;
}

static inline void test_fail(const char *name)
{
    printf("[FAIL] %s\n", name);
    g_fail++;
}

__attribute__((noinline)) static void recurse_burn(int depth)
{
    volatile uint32_t burn[24];
    int i;

    for (i = 0; i < 24; i++)
        burn[i] = (uint32_t)(depth + i);

    if (depth > 0)
        recurse_burn(depth - 1);

    if (burn[0] == 0xFFFFFFFFu)
        kv_wdt_kick();
}

__attribute__((noinline)) static void trigger_bad_sp(uint32_t bad_sp)
{
    asm volatile (
        "mv t0, sp\n\t"
        "mv sp, %0\n\t"
        "mv sp, t0\n\t"
        :
        : "r"(bad_sp)
        : "t0", "memory"
    );
}

static void stack_overflow_handler(kv_trap_frame_t *frame)
{
    uint16_t inst16 = *(volatile uint16_t *)(uintptr_t)frame->mepc;
    uint32_t step = ((inst16 & 0x3u) != 0x3u) ? 2u : 4u;

    g_overflow_seen++;
    g_last_mcause = frame->mcause;
    g_last_mtval = frame->mtval;

    frame->mepc += step;
}

int main(void)
{
    uint32_t sp_now;
    uint32_t guard;
    uint32_t spmin;

    printf("\n=== Stack Guard CSR Test ===\n");

    kv_exc_register(KV_EXC_STACK_OVERFLOW, stack_overflow_handler);

    // Subtest 1: guard disabled, recurse deeply, no overflow trap expected.
    write_csr_sguard_base(0u);
    write_csr_spmin(0xFFFFFFFFu);
    recurse_burn(14);
    spmin = read_csr_spmin();
    if (g_overflow_seen == 0 && spmin != 0xFFFFFFFFu) {
        test_pass("guard disabled + spmin tracks low-water mark");
    } else {
        test_fail("guard disabled + spmin tracks low-water mark");
        printf("  overflow_seen=%d spmin=0x%08lx\n", g_overflow_seen, (unsigned long)spmin);
    }

    // Subtest 2: guard enabled with margin, shallow recursion should pass.
    g_overflow_seen = 0;
    asm volatile ("mv %0, sp" : "=r"(sp_now));
    guard = sp_now - 4096u;
    write_csr_sguard_base(guard);
    write_csr_spmin(0xFFFFFFFFu);
    recurse_burn(4);
    spmin = read_csr_spmin();
    if (g_overflow_seen == 0 && spmin >= guard && spmin < sp_now) {
        test_pass("guard enabled with margin");
    } else {
        test_fail("guard enabled with margin");
         printf("  overflow_seen=%d spmin=0x%08lx guard=0x%08lx sp=0x%08lx\n",
             g_overflow_seen, (unsigned long)spmin, (unsigned long)guard, (unsigned long)sp_now);
    }

    // Subtest 3: force SP write below guard and validate trap metadata.
    g_overflow_seen = 0;
    asm volatile ("mv %0, sp" : "=r"(sp_now));
    guard = sp_now - 64u;
    write_csr_sguard_base(guard);
    g_expected_bad_sp = sp_now - 128u;
    trigger_bad_sp(g_expected_bad_sp);
    write_csr_sguard_base(0u);
    if (g_overflow_seen == 1 &&
        g_last_mcause == EXCEPTION_STACK_OVERFLOW &&
        g_last_mtval == g_expected_bad_sp) {
        test_pass("tight guard triggers cause=16 and mtval=bad_sp");
    } else {
        test_fail("tight guard triggers cause=16 and mtval=bad_sp");
         printf("  overflow_seen=%d mcause=0x%08lx mtval=0x%08lx expected=0x%08lx\n",
             g_overflow_seen,
             (unsigned long)g_last_mcause,
             (unsigned long)g_last_mtval,
             (unsigned long)g_expected_bad_sp);
    }

    // Subtest 4: SPMIN reset and re-learning.
    write_csr_sguard_base(0u);
    write_csr_spmin(0xFFFFFFFFu);
    recurse_burn(8);
    spmin = read_csr_spmin();
    if (spmin != 0xFFFFFFFFu) {
        test_pass("spmin reset + re-learn");
    } else {
        test_fail("spmin reset + re-learn");
    }

    printf("Summary: pass=%d fail=%d\n", (int)g_pass, (int)g_fail);
    kv_magic_exit(g_fail ? 1 : 0);

    while (1) {
        asm volatile ("nop");
    }

    return 0;
}
