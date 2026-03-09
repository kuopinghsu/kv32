/**
 * @file mrtos.h
 * @brief Mini-RTOS public API.
 *
 * Provides:
 *  - Multi-priority round-robin task scheduler
 *  - Mutex with priority inheritance (prevents priority inversion)
 *  - Counting semaphore
 *
 * Usage:
 * @code
 *   #include "mrtos.h"
 *
 *   static mrtos_tcb_t task1_tcb;
 *   static uint8_t     task1_stack[512];
 *
 *   static void task1(void *arg) {
 *       while (1) { ...; mrtos_yield(); }
 *   }
 *
 *   int main(void) {
 *       mrtos_init();
 *       mrtos_task_create(&task1_tcb, "t1", task1, NULL,
 *                         1, task1_stack, sizeof(task1_stack));
 *       mrtos_start();   // never returns
 *   }
 * @endcode
 *
 * @defgroup mrtos Mini-RTOS
 * @{
 */

#ifndef MRTOS_H
#define MRTOS_H

#include <stdint.h>
#include "mrtos_config.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ════════════════════════════════════════════════════════════════════
 * Forward declarations
 * ═══════════════════════════════════════════════════════════════════ */

struct mrtos_tcb;
struct mrtos_mutex;
struct mrtos_sem;

/* ════════════════════════════════════════════════════════════════════
 * Task
 * ═══════════════════════════════════════════════════════════════════ */

/** Task state machine values. */
typedef enum {
    MRTOS_TASK_READY   = 0, /**< In the ready queue, waiting for CPU.       */
    MRTOS_TASK_RUNNING = 1, /**< Currently executing on the CPU.            */
    MRTOS_TASK_BLOCKED = 2, /**< Waiting on a mutex or semaphore.           */
    MRTOS_TASK_DELAYED = 3, /**< Sleeping for a fixed number of ticks.      */
    MRTOS_TASK_DEAD    = 4, /**< Task has returned; stack can be reclaimed. */
} mrtos_state_t;

/**
 * @brief Task Control Block (TCB).
 *
 * Declare one statically per task and pass it to mrtos_task_create().
 * Do not access fields directly; use the API.
 */
typedef struct mrtos_tcb {
    void                *sp;             /**< Saved stack pointer (context frame). */
    const char          *name;           /**< Human-readable name for debugging.   */
    uint8_t              priority;       /**< Base (nominal) priority.             */
    uint8_t              eff_priority;   /**< Effective priority (may be raised).  */
    mrtos_state_t        state;          /**< Current scheduler state.             */
    uint32_t             wake_tick;      /**< Tick to wake on (DELAYED state).     */

    /* Ready / blocked doubly-linked list links. */
    struct mrtos_tcb    *next;
    struct mrtos_tcb    *prev;

    /* Priority-inheritance: mutex this task is currently blocked on. */
    struct mrtos_mutex  *blocked_on;
} mrtos_tcb_t;

/**
 * @brief Create and register a task.
 *
 * @param tcb        Caller-allocated TCB (static storage recommended).
 * @param name       Short name string for debugging (not copied).
 * @param entry      Task function; receives @p arg, must not return.
 *                   If it does return, the task is silently terminated.
 * @param arg        Opaque argument forwarded to @p entry.
 * @param priority   Priority level: 0 = highest, MRTOS_MAX_PRIORITY-1 = lowest.
 * @param stack      Pointer to the task's stack buffer.
 * @param stack_size Size of the stack buffer in bytes (min 256).
 */
void mrtos_task_create(mrtos_tcb_t *tcb,
                       const char  *name,
                       void       (*entry)(void *),
                       void        *arg,
                       uint8_t      priority,
                       void        *stack,
                       uint32_t     stack_size);

/**
 * @brief Yield the CPU to another ready task of the same or higher priority.
 *
 * The calling task re-enters the tail of its priority queue.
 * Returns after the task is rescheduled.
 */
void mrtos_yield(void);

/**
 * @brief Suspend the calling task for @p ticks scheduler ticks.
 *
 * @param ticks  Number of ticks to sleep (0 = yield once).
 */
void mrtos_delay(uint32_t ticks);

/** @brief Return the TCB of the currently-running task. */
mrtos_tcb_t *mrtos_current_task(void);

/** @brief Return the global tick counter (incremented once per OS tick). */
uint32_t mrtos_tick_count(void);

/* ════════════════════════════════════════════════════════════════════
 * Mutex — with priority inheritance
 * ═══════════════════════════════════════════════════════════════════ */

/**
 * @brief Mutex object.
 *
 * Supports **priority inheritance** to prevent priority inversion:
 * when a high-priority task H blocks on a mutex held by low-priority
 * task L, L's effective priority is temporarily raised to H's until
 * the mutex is released.
 */
typedef struct mrtos_mutex {
    struct mrtos_tcb *owner;    /**< Task currently holding the mutex.         */
    struct mrtos_tcb *waiters;  /**< Head of wait list (highest priority first). */
} mrtos_mutex_t;

/**
 * @brief Initialise a mutex to unlocked state.
 * @param m  Mutex object; must not be NULL.
 */
void mrtos_mutex_init(mrtos_mutex_t *m);

/**
 * @brief Acquire a mutex, blocking until it becomes available.
 *
 * If the mutex is held by a lower-priority task, that task's effective
 * priority is raised (priority inheritance) until the mutex is released.
 *
 * @param m  Initialised mutex object.
 */
void mrtos_mutex_lock(mrtos_mutex_t *m);

/**
 * @brief Release a mutex previously acquired with mrtos_mutex_lock().
 *
 * Restores the owner's effective priority and wakes the
 * highest-priority waiter (if any).
 *
 * @param m  Initialised mutex object (must be owned by the caller).
 */
void mrtos_mutex_unlock(mrtos_mutex_t *m);

/* ════════════════════════════════════════════════════════════════════
 * Semaphore — counting
 * ═══════════════════════════════════════════════════════════════════ */

/**
 * @brief Counting semaphore object.
 */
typedef struct mrtos_sem {
    uint32_t          count;    /**< Current count.                      */
    struct mrtos_tcb *waiters;  /**< Head of wait list (FIFO order).     */
} mrtos_sem_t;

/**
 * @brief Initialise a semaphore.
 * @param s              Semaphore object.
 * @param initial_count  Starting count (0 = signalling semaphore).
 */
void mrtos_sem_init(mrtos_sem_t *s, uint32_t initial_count);

/**
 * @brief Acquire (P / down / wait) the semaphore.
 *
 * Blocks if count == 0 until another task or ISR calls mrtos_sem_post().
 *
 * @param s  Initialised semaphore.
 */
void mrtos_sem_wait(mrtos_sem_t *s);

/**
 * @brief Release (V / up / post) the semaphore.
 *
 * Increments the count or wakes a waiting task.
 * Safe to call from a task context.
 *
 * @param s  Initialised semaphore.
 */
void mrtos_sem_post(mrtos_sem_t *s);

/**
 * @brief Release the semaphore from an interrupt service routine.
 *
 * Only @c mrtos_sem_post_from_isr() and @c mrtos_sem_post() differ in
 * that the ISR variant does not attempt to yield after posting; the
 * context switch (if needed) happens automatically on ISR exit.
 *
 * @param s  Initialised semaphore.
 */
void mrtos_sem_post_from_isr(mrtos_sem_t *s);

/* ════════════════════════════════════════════════════════════════════
 * Kernel lifecycle
 * ═══════════════════════════════════════════════════════════════════ */

/**
 * @brief Initialise the kernel data structures.
 *
 * Must be called once before mrtos_task_create() and mrtos_start().
 */
void mrtos_init(void);

/**
 * @brief Start the scheduler; never returns.
 *
 * Installs the RTOS trap vector, starts the tick timer, and transfers
 * control to the highest-priority ready task.
 */
void mrtos_start(void);

/**
 * @brief Advance the tick counter and run the scheduler.
 *
 * Called automatically from the CLINT timer ISR; do not call directly
 * unless you are implementing a custom port.
 */
void mrtos_tick(void);

/**
 * @brief Request a context switch at the next ISR exit.
 *
 * Used internally to trigger context switches from within kernel
 * primitives that run inside a critical section.
 */
void mrtos_request_switch(void);

#ifdef __cplusplus
}
#endif

/** @} */
#endif /* MRTOS_H */
