// ============================================================================
// File: nested_irq.c
// Project: KV32 RISC-V Processor
// Description: Nested interrupt test using two axi_timer channels via PLIC.
//
// Test design:
//   Timer 0: period N = 200000 cycles, PLIC source 6 (KV_PLIC_SRC_TIMER0), priority 1
//   Timer 1: period N/200 = 1000 cycles, PLIC source 7 (KV_PLIC_SRC_TIMER1), priority 2
//
// Nesting mechanism — WFI-based (simulator-agnostic):
//   The timer0 ISR raises the PLIC threshold to 1 (blocking timer0 self-preemption but
//   allowing timer1 prio=2), re-enables MIE, then executes WFI.  The CPU suspends until
//   timer1 fires.  The nested timer1 ISR runs and returns; MRET wakes the CPU at the
//   instruction after WFI.  csrrci then atomically closes the nesting window.
//
//   Why WFI instead of a spin loop:
//     In RTL simulation each timer1 ISR takes ~380 cycles (AXI pipeline stalls for PLIC
//     claim/complete and timer register accesses).  With TIMER1_PERIOD=1000 this leaves
//     ~620 cycles of margin after the nested ISR completes and csrrci can commit before
//     the next timer1 fire — safe on all three simulators.
//     With TIMER1_PERIOD=400 the margin shrinks to ~20 cycles, which is not enough when
//     AXI stall counts vary, causing a cascade of nested traps that overflows the stack.
//
// Both TIMER0 and TIMER1 interrupts arrive as MEI (Machine External Interrupt,
// cause 11).  A single mei_handler dispatches based on the PLIC claim result.
//
// Timer 0 ISR path (lower-priority):
//   1. Claim PLIC → src 6; clear timer0 INT_STATUS; t0_entry_count++
//   2. Raise PLIC threshold to 1 (blocks timer0 re-entry; timer1 prio=2 still passes)
//   3. Re-enable global MIE → timer1 can now preempt
//   4. WFI — CPU suspends until timer1 fires; nested timer1 ISR runs and returns
//   5. Disable MIE (csrrci); t0_exit_count++
//   6. Restore threshold=0; complete source 6
//
// Timer 1 ISR path (higher-priority, may be nested inside timer 0):
//   1. Claim PLIC → src 7; clear timer1 INT_STATUS; t1_count++
//   2. If t0_entry_count > t0_exit_count → nested_detected = 1
//   3. Complete source 7
//
// Pass criteria:
//   - nested_detected == 1  (timer1 fired while timer0 ISR was active)
//   - t1_count >= 4         (timer1 fired several times)
//   - t0_entry_count >= 2   (timer0 ISR ran at least twice)
//   - t0_entry_count == t0_exit_count (all timer0 ISRs completed cleanly)
// ============================================================================

#include <stdint.h>
#include <stdio.h>
#include "kv_platform.h"
#include "kv_timer.h"
#include "kv_plic.h"
#include "kv_irq.h"

// ── Timer periods ──────────────────────────────────────────────────────────
#define TIMER0_PERIOD   200000u   // low-priority timer
#define TIMER1_PERIOD     1000u   // high-priority timer  (TIMER0_PERIOD / 200)

// ── Shared state (touched by ISRs) ────────────────────────────────────────
static volatile uint32_t t0_entry_count = 0;
static volatile uint32_t t0_exit_count  = 0;
static volatile uint32_t t1_count       = 0;
static volatile uint32_t nested_detected = 0;  // set when timer1 fires inside timer0 ISR

// ── Combined MEI dispatcher ────────────────────────────────────────────────
// Both TIMER0 and TIMER1 interrupts arrive as MEI.  The PLIC claim identifies
// the source so that each path is handled independently.
static void mei_handler(uint32_t cause)
{
    (void)cause;
    uint32_t src = kv_plic_claim();

    if (src == (uint32_t)KV_PLIC_SRC_TIMER0) {
        // ── Timer 0 (lower-priority) path ─────────────────────────────────
        kv_timer_clear_int(1u << 0);
        t0_entry_count++;

        // Raise PLIC threshold to 1.  Timer0 prio = 1 <= threshold, so
        // timer0 cannot re-preempt itself.  Timer1 prio = 2 > threshold,
        // so it can still be delivered once MIE is re-enabled below.
        kv_plic_set_threshold(1u);

        // Re-enable global MIE: opens the nested-interrupt window.
        kv_irq_enable();

        // WFI: suspend until timer1 fires.  The CPU halts here; when
        // timer1's MEI arrives the nested timer1 ISR runs and returns
        // via MRET to the instruction after this WFI.  No spin loop
        // is needed — one WFI catches exactly one timer1 event,
        // regardless of the ISR/period ratio in each simulator.
        asm volatile("wfi");

        // Close the preemption window before updating the exit counter.
        // Use a single atomic CSR instruction so no extra interrupt can
        // slip in between the read and clear phases.
        asm volatile("csrrci zero, mstatus, 8");
        t0_exit_count++;

        // Restore threshold and complete this interrupt.
        kv_plic_set_threshold(0u);
        kv_plic_complete(src);

    } else if (src == (uint32_t)KV_PLIC_SRC_TIMER1) {
        // ── Timer 1 (higher-priority) path — may execute nested inside timer0
        kv_timer_clear_int(1u << 1);
        t1_count++;

        // If timer0 entry count is ahead of exit count we are inside a
        // timer0 ISR — this is the nested preemption we want to detect.
        if (t0_entry_count > t0_exit_count)
            nested_detected = 1;

        kv_plic_complete(src);

    } else {
        // Spurious or unknown source — complete and continue.
        if (src) kv_plic_complete(src);
    }
}

// ── Main ──────────────────────────────────────────────────────────────────
int main(void)
{
    int pass = 0, fail = 0;

    printf("============================================================\n");
    printf("  Nested Interrupt Test\n");
    printf("  Timer0: period=%u cycles, PLIC src=%d, prio=1\n",
           TIMER0_PERIOD, KV_PLIC_SRC_TIMER0);
    printf("  Timer1: period=%u cycles, PLIC src=%d, prio=2\n",
           TIMER1_PERIOD, KV_PLIC_SRC_TIMER1);
    printf("============================================================\n\n");

    // ------------------------------------------------------------------
    // Init timers (auto-reload on COMPARE2 match, interrupt on COMPARE2)
    // ------------------------------------------------------------------
    kv_timer_init();

    // Channel 0: period = TIMER0_PERIOD, no prescale
    KV_TIMER_COMPARE1(0) = 0;
    KV_TIMER_COMPARE2(0) = TIMER0_PERIOD - 1u;
    KV_TIMER_INT_ENABLE  = 0x3u;    // enable channels 0 and 1 globally
    KV_TIMER_CTRL(0) = KV_TIMER_CTRL_EN | KV_TIMER_CTRL_INT_EN;

    // Channel 1: period = TIMER1_PERIOD, no prescale
    KV_TIMER_COMPARE1(1) = 0;
    KV_TIMER_COMPARE2(1) = TIMER1_PERIOD - 1u;
    KV_TIMER_CTRL(1) = KV_TIMER_CTRL_EN | KV_TIMER_CTRL_INT_EN;

    // ------------------------------------------------------------------
    // Configure PLIC:
    //   Timer0 → source 6, priority 1
    //   Timer1 → source 7, priority 2
    //   Threshold = 0 (all enabled sources can fire)
    // ------------------------------------------------------------------
    kv_plic_set_priority(KV_PLIC_SRC_TIMER0, 1u);
    kv_plic_set_priority(KV_PLIC_SRC_TIMER1, 2u);
    kv_plic_enable_source(KV_PLIC_SRC_TIMER0);
    kv_plic_enable_source(KV_PLIC_SRC_TIMER1);
    kv_plic_set_threshold(0u);

    // Register the combined MEI handler and enable external interrupts.
    kv_irq_register(KV_CAUSE_MEI, mei_handler);
    kv_irq_source_enable(KV_IRQ_MEIE);
    kv_irq_enable();

    printf("[TEST] Waiting for nested interrupt to occur...\n");

    // Wait until timer0 has COMPLETED at least twice (checking exit count to
    // avoid a race where we see entry=2 before the ISR finishes) and timer1
    // has fired at least 4 times, or a safety timeout expires.
    uint32_t timeout = 0;
    while ((t0_exit_count < 2 || t1_count < 4) && timeout < 100000000u) {
        timeout++;
        asm volatile("nop");
    }

    // Atomically disable interrupts (single CSR, no 2-cycle race window).
    asm volatile("csrrci zero, mstatus, 8");

    // Disable timers
    kv_timer_stop(0);
    kv_timer_stop(1);

    // Print counters
    printf("  t0_entry_count  = %lu\n", (unsigned long)t0_entry_count);
    printf("  t0_exit_count   = %lu\n", (unsigned long)t0_exit_count);
    printf("  t1_count        = %lu\n", (unsigned long)t1_count);
    printf("  nested_detected = %lu\n", (unsigned long)nested_detected);
    printf("\n");

    // ------------------------------------------------------------------
    // Pass/Fail checks
    // ------------------------------------------------------------------
    printf("[CHECK 1] Timer1 fired at least 4 times (t1_count >= 4): ");
    if (t1_count >= 4) {
        printf("PASS (t1_count=%lu)\n", (unsigned long)t1_count);
        pass++;
    } else {
        printf("FAIL (t1_count=%lu)\n", (unsigned long)t1_count);
        fail++;
    }

    printf("[CHECK 2] Timer0 ISR completed at least twice (t0_exit >= 2): ");
    if (t0_exit_count >= 2) {
        printf("PASS (t0_exit=%lu)\n", (unsigned long)t0_exit_count);
        pass++;
    } else {
        printf("FAIL (t0_exit=%lu)\n", (unsigned long)t0_exit_count);
        fail++;
    }

    printf("[CHECK 3] Nested interrupt detected (timer1 preempted timer0 ISR): ");
    if (nested_detected) {
        printf("PASS\n");
        pass++;
    } else {
        printf("FAIL (nested_detected=0)\n");
        fail++;
    }

    printf("[CHECK 4] ISR count balanced (t0_entry == t0_exit): ");
    if (t0_entry_count == t0_exit_count) {
        printf("PASS (entry=%lu exit=%lu)\n",
               (unsigned long)t0_entry_count, (unsigned long)t0_exit_count);
        pass++;
    } else {
        printf("FAIL (entry=%lu exit=%lu)\n",
               (unsigned long)t0_entry_count, (unsigned long)t0_exit_count);
        fail++;
    }

    printf("\n============================================================\n");
    printf("  Results: %d PASS, %d FAIL\n", pass, fail);
    printf("============================================================\n");

    // Write exit code directly to the magic exit register (avoids libc
    // cleanup which can crash when timer interrupts have been active).
    *(volatile uint32_t *)(KV_MAGIC_BASE + 0x0004UL) = (uint32_t)(fail == 0 ? 0u : 1u);
    while (1) asm volatile("wfi");  // should not reach here
}

