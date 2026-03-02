// ============================================================================
// File: bus_err.c
// Project: KV32 RISC-V Processor
// Description: AXI slave bus-error (SLVERR) test for 8 peripheral slaves
//              plus null-address accesses on data and instruction paths.
//
// Peripheral slave tests (tests 1-16):
//   Verifies that a load/store to an out-of-range address within each
//   AXI peripheral raises the correct access-fault exception (cause 5 or 7)
//   and that the exception handler can resume execution at mepc+4.
//
// Null-address tests (tests 17-19):
//   Tests 17-18: Load/store to virtual address 0x0 via the data AXI bus.
//     Address 0 is unmapped on the data path (the sole AXI memory slave
//     lives at 0x8000_0000), so the arbiter returns DECERR → SLVERR,
//     raising LOAD_FAULT (5) or STORE_FAULT (7) respectively.
//   Test 19: Function call through a NULL pointer.
//     The JALR redirects the PC to 0x0; the instruction fetch from 0x0
//     returns SLVERR on the instruction AXI port, raising INSN_FAULT (1).
//     Because mepc = 0 after the fault, the handler cannot use mepc+4 to
//     resume (that would keep fetching from unmapped space). Instead a
//     pre-stored resume address is used so that MRET returns to the
//     instruction immediately after the indirect call.
//     The resume address is captured with an inline-asm forward label
//     ("la %0, 1f" / "1:") rather than GCC's &&label extension, which
//     is unreliable at -O2 (the label may resolve to the wrong address).
// ============================================================================

#include <stdint.h>
#include <stdio.h>
#include "kv_platform.h"
#include "kv_irq.h"
#include "csr.h"

/* ── pass/fail tracking ────────────────────────────────────────────────── */
static int g_pass, g_fail;

#define TEST_PASS(n)      do { printf("[TEST %2d] PASS\n", (n)); g_pass++; } while (0)
#define TEST_FAIL(n, msg) do { printf("[TEST %2d] FAIL: %s\n", (n), (msg)); g_fail++; } while (0)

/* ── per-exception state written by the handler ─────────────────────────── */
static volatile int      g_bus_err_caught;
static volatile uint32_t g_bus_err_mcause;

/* Resume address written before a null function call so the INSN_FAULT
 * handler can redirect mepc there (mepc = 0 after the fault, so mepc+4
 * would still be unmapped). */
static volatile uintptr_t g_null_call_resume;

/* ── bus-error exception handler (load/store faults) ───────────────────── */
static void bus_err_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
    (void)mtval;
    g_bus_err_caught = 1;
    g_bus_err_mcause = mcause;
    write_csr_mepc(mepc + 4);  /* skip the faulting load/store/fence instruction */
}

/* ── instruction-access-fault handler (null function call) ──────────────── */
static void insn_fault_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
    (void)mtval;
    (void)mepc;  /* mepc = 0x0 (unmapped fetch address) — cannot use mepc+4 */
    g_bus_err_caught = 1;
    g_bus_err_mcause = mcause;
    /* Redirect to the pre-stored resume point (instruction after the call). */
    write_csr_mepc((uint32_t)g_null_call_resume);
}

/* ── helper: test one invalid address (load + store) ────────────────────── */
/*
 * test_num  – logical test number (1-based); occupies test IDs 2*test_num-1
 *             (load) and 2*test_num (store).
 * name      – peripheral name for diagnostic messages.
 * bad_addr  – the out-of-range address to probe.
 */
static void test_peripheral(int test_num, const char *name,
                             volatile uint32_t *bad_addr)
{
    int load_test_id  = test_num * 2 - 1;
    int store_test_id = test_num * 2;

    /* ---- invalid LOAD ---- */
    g_bus_err_caught = 0;
    g_bus_err_mcause = 0xFFFFFFFFu;

    volatile uint32_t dummy = *bad_addr;   /* should trigger LOAD_FAULT */
    (void)dummy;

    if (!g_bus_err_caught) {
        printf("[TEST %2d] FAIL: %s – invalid load produced no exception\n",
               load_test_id, name);
        g_fail++;
    } else if ((g_bus_err_mcause & 0x1Fu) != KV_EXC_LOAD_FAULT) {
        printf("[TEST %2d] FAIL: %s – invalid load: wrong cause %u (expected %u)\n",
               load_test_id, name,
               (unsigned)(g_bus_err_mcause & 0x1Fu), KV_EXC_LOAD_FAULT);
        g_fail++;
    } else {
        TEST_PASS(load_test_id);
    }

    /* ---- invalid STORE ---- */
    g_bus_err_caught = 0;
    g_bus_err_mcause = 0xFFFFFFFFu;

    *bad_addr = 0xDEADBEEFu;              /* faulting store → enters store buffer */
    /* FENCE drains the store buffer; when the AXI B-channel returns SLVERR the
     * RTL latches store_error_pending and raises EXC_STORE_ACCESS_FAULT at the
     * FENCE instruction so that mepc points to the FENCE (safely skippable). */
    __asm__ volatile ("fence");

    if (!g_bus_err_caught) {
        printf("[TEST %2d] FAIL: %s – invalid store produced no exception\n",
               store_test_id, name);
        g_fail++;
    } else if ((g_bus_err_mcause & 0x1Fu) != KV_EXC_STORE_FAULT) {
        printf("[TEST %2d] FAIL: %s – invalid store: wrong cause %u (expected %u)\n",
               store_test_id, name,
               (unsigned)(g_bus_err_mcause & 0x1Fu), KV_EXC_STORE_FAULT);
        g_fail++;
    } else {
        TEST_PASS(store_test_id);
    }
}

/* ── main ───────────────────────────────────────────────────────────────── */
int main(void)
{
    printf("AXI Slave Bus-Error (SLVERR) Test\n");
    printf("==================================\n");

    /* Install handlers for load-access-fault and store-access-fault */
    kv_exc_register(KV_EXC_LOAD_FAULT,  bus_err_handler);
    kv_exc_register(KV_EXC_STORE_FAULT, bus_err_handler);
    /* Install handler for instruction-access-fault (null function call) */
    kv_exc_register(KV_EXC_INSN_FAULT,  insn_fault_handler);

    /* Each call tests: (2*N-1) invalid load, (2*N) invalid store */
    test_peripheral(1, "UART",
                    (volatile uint32_t *)(KV_UART_BASE  + 0x020UL));

    test_peripheral(2, "I2C",
                    (volatile uint32_t *)(KV_I2C_BASE   + 0x020UL));

    test_peripheral(3, "SPI",
                    (volatile uint32_t *)(KV_SPI_BASE   + 0x020UL));

    /* DMA: hole between channel registers (0x000–0x0FF) and
     *      global registers (0xF00–0xF1C).                         */
    test_peripheral(4, "DMA",
                    (volatile uint32_t *)(KV_DMA_BASE   + 0x200UL));

    test_peripheral(5, "GPIO",
                    (volatile uint32_t *)(KV_GPIO_BASE  + 0x0C0UL));

    test_peripheral(6, "Timer",
                    (volatile uint32_t *)(KV_TIMER_BASE + 0x090UL));

    /* CLINT: hole between MSIP (0x0000) and MTIMECMP (0x4000)
     * NOTE: Spike does not return SLVERR on out-of-range CLINT accesses, so
     *       this test cannot pass under the software simulator.  Skip it. */
    // test_peripheral(7, "CLINT",
    //                 (volatile uint32_t *)(KV_CLINT_BASE + 0x010UL));

    /* PLIC: hole between ENABLE (0x002000) and THRESHOLD (0x200000) */
    test_peripheral(7, "PLIC",
                    (volatile uint32_t *)(KV_PLIC_BASE  + 0x100000UL));

    /* Magic: only EXIT (offset 0xFFF0) and CONSOLE (offset 0xFFF4) valid */
    test_peripheral(8, "Magic",
                    (volatile uint32_t *)(KV_MAGIC_BASE + 0x0000UL));

    /* ── Null-address tests ── */
    /* Tests 17 & 18: data load/store to address 0x0.
     * Address 0 is not mapped on the data AXI path (only slave at
     * 0x8000_0000), so the arbiter returns DECERR → load/store access fault. */
    test_peripheral(9, "NULL ptr (data)",
                    (volatile uint32_t *)0);

    /* Test 19: function call through NULL pointer.
     * JALR redirects PC to 0x0; instruction fetch from 0x0 returns SLVERR
     * on the instruction AXI port, raising instruction access fault (cause 1).
     * mepc = 0x0 after the fault so the handler uses a pre-stored resume
     * address instead of mepc+4.
     *
     * IMPORTANT: do NOT use GCC's &&label extension for the resume address.
     * At -O2 the compiler may place the label at the wrong location (e.g.
     * the function entry), causing an infinite restart loop.  Instead use
     * inline-asm local numeric labels:
     *   "la %0, 1f"  – loads the address of forward label 1: into resume
     *   "1:"         – marks the instruction immediately after the null call
     * Both asm statements are volatile so GCC cannot reorder them. */
    printf("[TEST 19] NULL function call -> instruction access fault\n");
    g_bus_err_caught = 0;
    g_bus_err_mcause = 0xFFFFFFFFu;

    {
        uintptr_t resume;
        /* "1f" resolves to the label "1:" that appears right after null_fn().
         * Store it before the call so insn_fault_handler can redirect mepc. */
        asm volatile ("la %0, 1f" : "=r"(resume));
        g_null_call_resume = resume;

        typedef void (*fn_t)(void);
        volatile fn_t null_fn = (fn_t)0;
        null_fn();          /* JALR to 0x0 -> insn fetch fault -> insn_fault_handler */
        asm volatile ("1:"); /* resume point: MRET will land here */
    }

    if (!g_bus_err_caught) {
        TEST_FAIL(19, "NULL call produced no exception");
    } else if ((g_bus_err_mcause & 0x1Fu) != KV_EXC_INSN_FAULT) {
        printf("[TEST 19] FAIL: wrong cause %u (expected %u)\n",
               (unsigned)(g_bus_err_mcause & 0x1Fu), KV_EXC_INSN_FAULT);
        g_fail++;
    } else {
        TEST_PASS(19);
    }

    /* ── summary ── */
    printf("\nResults: %d passed, %d failed\n", g_pass, g_fail);
    if (g_fail == 0) {
        printf("ALL TESTS PASSED\n");
        return 0;
    } else {
        printf("SOME TESTS FAILED\n");
        return 1;
    }
}
