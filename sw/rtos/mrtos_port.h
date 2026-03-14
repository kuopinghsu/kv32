/**
 * @file mrtos_port.h
 * @brief Mini-RTOS portable-layer interface.
 *
 * Every port **must** implement the functions declared here.
 * The RISC-V / CLINT implementation lives in mrtos_riscv.c.
 *
 * @defgroup mrtos_port Portable Layer
 * @ingroup mrtos
 * @{
 */

#ifndef MRTOS_PORT_H
#define MRTOS_PORT_H

#include <stdint.h>

/*
 * Optional port quirk: force a WFI boundary after a blocking semaphore wait
 * yields.  This is useful for simulator ports where an MSIP MMIO write may
 * retire before trap entry is architecturally visible to software.
 *
 * Enabled by default only when explicitly passed via -D, e.g. for Spike:
 *   -DMRTOS_PORT_SEM_WAIT_WFI_SYNC=1
 */
#ifndef MRTOS_PORT_SEM_WAIT_WFI_SYNC
#define MRTOS_PORT_SEM_WAIT_WFI_SYNC 0
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ── Context-frame size ───────────────────────────────────────────── */

/**
 * Size of the saved-context frame pushed onto each task stack.
 *
 * Layout (RISC-V RV32):
 *   Offset  Register
 *     0     mstatus
 *     4     mepc
 *     8     x1  (ra)
 *    12     x3  (gp)
 *    16     x4  (tp)
 *    20     x5  (t0)
 *    24     x6  (t1)
 *    28     x7  (t2)
 *    32     x8  (s0/fp)
 *    36     x9  (s1)
 *    40     x10 (a0)
 *    44     x11 (a1)
 *    48     x12 (a2)
 *    52     x13 (a3)
 *    56     x14 (a4)
 *    60     x15 (a5)
 *    64     x16 (a6)
 *    68     x17 (a7)
 *    72     x18 (s2)
 *    76     x19 (s3)
 *    80     x20 (s4)
 *    84     x21 (s5)
 *    88     x22 (s6)
 *    92     x23 (s7)
 *    96     x24 (s8)
 *   100     x25 (s9)
 *   104     x26 (s10)
 *   108     x27 (s11)
 *   112     x28 (t3)
 *   116     x29 (t4)
 *   120     x30 (t5)
 *   124     x31 (t6)
 *   128     x2  (sp, original value before frame allocation)
 * Total: 132 bytes
 */
#define MRTOS_CTX_FRAME_SIZE  132U

/** Index helpers into the 32-bit word array at the frame base. */
#define MRTOS_FRAME_MSTATUS   0   /**< mstatus */
#define MRTOS_FRAME_MEPC      1   /**< mepc (return address)       */
#define MRTOS_FRAME_RA        2   /**< x1  ra                      */
#define MRTOS_FRAME_GP        3   /**< x3  gp                      */
#define MRTOS_FRAME_TP        4   /**< x4  tp                      */
#define MRTOS_FRAME_T0        5   /**< x5  t0                      */
#define MRTOS_FRAME_A0        10  /**< x10 a0 (first arg)          */
#define MRTOS_FRAME_SP        32  /**< x2  sp (original)           */

/* ── Port API ─────────────────────────────────────────────────────── */

/**
 * @brief Install the RTOS trap vector and start the periodic tick timer.
 *
 * Called once from mrtos_start() before the first context switch.
 * The port must:
 *   1. Install a trap vector that saves all registers and calls
 *      mrtos_trap_handler() on every machine-mode trap.
 *   2. Program the CLINT mtimecmp so that timer interrupts fire at
 *      the frequency configured by MRTOS_TICK_HZ.
 *   3. Enable MTIE (machine timer interrupt) in mie.
 *   4. Optionally enable MSIE for software-triggered yields.
 */
void mrtos_port_init(void);

/**
 * @brief Enter the first task; never returns.
 *
 * Loads @p sp into the stack pointer and executes mret to switch into
 * the first task with interrupts enabled.
 *
 * @param sp  Initial stack frame pointer of the first task to run.
 */
void mrtos_port_start_first(void *sp);

/**
 * @brief Enter a critical section (disable interrupts).
 *
 * @return  The previous mstatus value (pass to mrtos_port_exit_critical).
 */
uint32_t mrtos_port_enter_critical(void);

/**
 * @brief Exit a critical section (restore interrupts).
 *
 * @param saved_mstatus  Value returned by mrtos_port_enter_critical().
 */
void mrtos_port_exit_critical(uint32_t saved_mstatus);

/**
 * @brief Request a cooperative context switch (yield).
 *
 * Triggers a machine-software interrupt so that the trap handler
 * performs the next scheduled context switch.
 * Must be called with interrupts enabled.
 */
void mrtos_port_yield(void);

/**
 * @brief Advance the CLINT mtimecmp by one tick interval.
 *
 * Called from the timer ISR after each tick to schedule the next one.
 */
void mrtos_port_ack_timer(void);

/**
 * @brief Change the timer tick interval at runtime.
 *
 * Safe to call from any task context.  The new period takes effect
 * immediately: mtimecmp is reprogrammed to mtime + @p clint_ticks.
 *
 * In trace-compare mode mtime advances once per retired instruction,
 * so setting @p clint_ticks to a small value (e.g. 10) triggers a
 * context switch approximately every 10 retired instructions — useful
 * for stressing div/mul operations across preemptions.
 *
 * @param clint_ticks  New period in mtime counts.  Must be >= 2.
 */
void mrtos_set_tick_period(uint32_t clint_ticks);

/**
 * @brief Return the current tick period in mtime counts.
 */
uint32_t mrtos_get_tick_period(void);

#ifdef __cplusplus
}
#endif

/** @} */
#endif /* MRTOS_PORT_H */
