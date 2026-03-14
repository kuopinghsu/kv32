/**
 * @file mrtos_config.h
 * @brief Mini-RTOS compile-time configuration.
 *
 * Override any of these macros via -D on the compiler command line or by
 * creating a project-local @c mrtos_user_config.h and defining
 * @c MRTOS_USER_CONFIG before including this header.
 *
 * @defgroup mrtos_config Configuration
 * @ingroup mrtos
 * @{
 */

#ifndef MRTOS_CONFIG_H
#define MRTOS_CONFIG_H

/* ── User override hook ───────────────────────────────────────────── */
#ifdef MRTOS_USER_CONFIG
#  include MRTOS_USER_CONFIG
#endif

/* ── Scheduler ────────────────────────────────────────────────────── */

/** Maximum number of user tasks (does not include the internal idle task). */
#ifndef MRTOS_MAX_TASKS
#  define MRTOS_MAX_TASKS       8
#endif

/**
 * Number of priority levels.  Level 0 is the **highest** priority;
 * level (MRTOS_MAX_PRIORITY-1) is the lowest (above the idle task).
 */
#ifndef MRTOS_MAX_PRIORITY
#  define MRTOS_MAX_PRIORITY    8
#endif

/** Tick frequency in Hz (timer interrupt rate). */
#ifndef MRTOS_TICK_HZ
#  define MRTOS_TICK_HZ         1000U
#endif

/* ── Port / BSP ───────────────────────────────────────────────────── */

/**
 * CLINT mtime clock frequency in Hz.
 * For the KV32 SoC default is 100 MHz; override per board.
 */
#ifndef MRTOS_CLINT_FREQ
#  define MRTOS_CLINT_FREQ      100000000UL
#endif

/** Idle task stack size in bytes.  Must be at least 256. */
#ifndef MRTOS_IDLE_STACK_SIZE
#  define MRTOS_IDLE_STACK_SIZE 512U
#endif

/* ── Derived constants (do not override) ─────────────────────────── */

/** mtime ticks per scheduler tick. */
#define MRTOS_TICKS_PER_SLOT  ((MRTOS_CLINT_FREQ) / (MRTOS_TICK_HZ))

/** @} */
#endif /* MRTOS_CONFIG_H */
