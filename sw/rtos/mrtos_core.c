/**
 * @file mrtos_core.c
 * @brief Mini-RTOS kernel core: task management and multi-priority round-robin scheduler.
 *
 * ### Scheduler design
 *
 * - **Priority queues**: One circular doubly-linked list per priority level.
 *   Priority 0 is the highest; priority (MRTOS_MAX_PRIORITY-1) is the lowest.
 * - **Round-robin**: Tasks at the same priority share the CPU in FIFO order.
 *   On each tick the running task is re-inserted at the tail of its queue,
 *   giving every peer one tick of CPU before it runs again.
 * - **Preemption**: The CLINT timer fires at MRTOS_TICK_HZ.  If a higher-
 *   priority task becomes ready (e.g. a semaphore is posted from an ISR),
 *   mrtos_request_switch() sets a pending flag that is acted on at ISR exit.
 * - **Idle task**: A built-in idle task at priority MRTOS_MAX_PRIORITY always
 *   keeps the ready queue non-empty.
 *
 * @ingroup mrtos
 */

#include <string.h>
#include "mrtos.h"
#include "mrtos_port.h"
#include "csr.h"

/* ════════════════════════════════════════════════════════════════════
 * Internal types
 * ═══════════════════════════════════════════════════════════════════ */

/** Head of the singly-linked delayed-task list. */
static mrtos_tcb_t *g_delayed_head;

/** Per-priority circular ready-queue heads.  NULL = empty. */
static mrtos_tcb_t *g_ready[MRTOS_MAX_PRIORITY + 1]; /* +1 for idle */

/** Bitmask: bit p set ⟹ g_ready[p] is non-empty. */
static uint32_t g_ready_mask;

/** Currently running task (NULL before mrtos_start). */
static mrtos_tcb_t *g_current;

/** Monotonic tick counter, wraps after ~49 days at 1 kHz. */
static volatile uint32_t g_tick_count;

/* ── Context-switch globals (written by C, read by assembly port) ── */

/**
 * @brief Non-zero when a context switch must be performed on trap exit.
 * Written by mrtos_request_switch(); read and cleared by the port's
 * trap-exit assembly sequence.
 */
volatile int      mrtos_ctx_switch_pending;

/**
 * @brief Pointer to the location where the current task's sp should be saved.
 * Set before triggering a context switch.
 */
volatile void   **mrtos_ctx_old_sp_ptr;

/**
 * @brief The stack pointer of the next task to run.
 * Set before triggering a context switch.
 */
volatile void    *mrtos_ctx_new_sp;

/**
 * @brief Stack guard values to be installed for the next task at trap-exit.
 */
volatile uint32_t mrtos_ctx_new_sguard_base;
volatile uint32_t mrtos_ctx_new_spmin;

/* ── Idle task ─────────────────────────────────────────────────────── */

static mrtos_tcb_t g_idle_tcb;
static uint8_t     g_idle_stack[MRTOS_IDLE_STACK_SIZE];

/* ════════════════════════════════════════════════════════════════════
 * Private helpers
 * ═══════════════════════════════════════════════════════════════════ */

/**
 * @brief Insert @p tcb at the tail of its effective-priority ready queue.
 * Must be called from a critical section.
 */
void mrtos_ready_insert(mrtos_tcb_t *tcb)
{
    uint8_t p = tcb->eff_priority;
    if (g_ready[p] == NULL) {
        tcb->next = tcb;
        tcb->prev = tcb;
        g_ready[p] = tcb;
    } else {
        mrtos_tcb_t *head = g_ready[p];
        mrtos_tcb_t *tail = head->prev;
        tail->next = tcb;
        tcb->prev  = tail;
        tcb->next  = head;
        head->prev = tcb;
    }
    g_ready_mask |= (1u << p);
}

/**
 * @brief Remove @p tcb from the ready queue.
 * Must be called from a critical section.
 */
void mrtos_ready_remove(mrtos_tcb_t *tcb)
{
    uint8_t p = tcb->eff_priority;
    if (tcb->next == tcb) {
        /* Last task at this priority. */
        g_ready[p]    = NULL;
        g_ready_mask &= ~(1u << p);
    } else {
        if (g_ready[p] == tcb) {
            g_ready[p] = tcb->next;
        }
        tcb->prev->next = tcb->next;
        tcb->next->prev = tcb->prev;
    }
    tcb->next = NULL;
    tcb->prev = NULL;
}

/**
 * @brief Return the highest-priority ready task without removing it.
 * Must be called from a critical section.
 */
static mrtos_tcb_t *schedule_pick(void)
{
    if (g_ready_mask == 0u) {
        return NULL; /* Should never happen while idle task exists. */
    }
    /* __builtin_ctz: count trailing zeros = index of lowest-numbered set bit. */
    uint32_t p = (uint32_t)__builtin_ctz(g_ready_mask);
    return g_ready[p];
}

/**
 * @brief Determine the next task and arm the context-switch globals.
 *
 * Does nothing if the current highest-priority ready task is the same
 * as g_current (single task at that priority, no switch needed).
 * Must be called from a critical section.
 */
static void do_schedule(void)
{
    /*
     * Pre-emption path (sem_post, mutex_unlock, ...): if the current task
     * is still RUNNING it was NOT explicitly put back by the caller
     * (unlike yield/delay/block which set state before calling us).
     * Re-insert it into the ready queue so it can be picked up later.
     */
    if (g_current != NULL && g_current->state == MRTOS_TASK_RUNNING) {
        g_current->state = MRTOS_TASK_READY;
        mrtos_ready_insert(g_current);
    }

    mrtos_tcb_t *next = schedule_pick();
    if (next == NULL || next == g_current) {
        /* No switch needed — current task stays (or becomes) the runner.
         * Cancel any stale switch state left by a previous do_schedule call
         * so the trap-exit does not execute a spurious context switch. */
        mrtos_ctx_switch_pending = 0;
        mrtos_ctx_old_sp_ptr     = NULL;
        mrtos_ctx_new_sp         = NULL;
        if (g_current != NULL && g_current->state == MRTOS_TASK_READY) {
            mrtos_ready_remove(g_current);
            g_current->state = MRTOS_TASK_RUNNING;
        }
        return;
    }

    /* Remove next from ready queue; it will be RUNNING. */
    mrtos_ready_remove(next);
    next->state = MRTOS_TASK_RUNNING;

    if (g_current != NULL) {
        g_current->spmin_saved = read_csr_spmin();
    }
    mrtos_ctx_new_sguard_base = next->sguard_base;
    mrtos_ctx_new_spmin = next->spmin_saved;

    /* Arm the port-level context-switch. */
    mrtos_ctx_old_sp_ptr      = (g_current != NULL) ? (volatile void **)&g_current->sp : NULL;
    mrtos_ctx_new_sp          = next->sp;
    mrtos_ctx_switch_pending  = 1;
    g_current                 = next;
}

/* ════════════════════════════════════════════════════════════════════
 * Idle task
 * ═══════════════════════════════════════════════════════════════════ */

static void idle_task(void *arg)
{
    (void)arg;
    /*
     * Spin idle loop — no WFI.
     *
     * WFI causes a 1-instruction trace divergence between RTL and kv32sim:
     * RTL wakes from WFI at PC+4 and retires the next instruction before
     * taking the pending interrupt, while kv32sim takes the trap with
     * mepc=PC+4 immediately without retiring any extra instruction.
     * A plain spin loop avoids this asymmetry and keeps traces identical.
     */
    while (1) {
        __asm__ volatile ("nop" ::: "memory");
    }
}

/* ════════════════════════════════════════════════════════════════════
 * Initialise context frame on a fresh stack
 * ═══════════════════════════════════════════════════════════════════ */

/**
 * @brief Prepare an initial context frame for a new task.
 *
 * The frame matches the layout described in mrtos_port.h so that
 * restoring it via the trap-exit sequence starts the task at @p entry
 * with @p arg in a0 and interrupts enabled.
 *
 * @param stack_top  Pointer to the byte just past the end of the stack.
 * @param entry      Task function.
 * @param arg        Argument forwarded to @p entry.
 * @return           Pointer to the base of the context frame (saved sp).
 */
static void *init_stack_frame(void *stack_top,
                               void (*entry)(void *),
                               void  *arg)
{
    /* Align down to 4-byte boundary. */
    uintptr_t top = (uintptr_t)stack_top & ~(uintptr_t)3u;

    /* Allocate the context frame. */
    uint32_t *frame = (uint32_t *)(top - MRTOS_CTX_FRAME_SIZE);
    memset(frame, 0, MRTOS_CTX_FRAME_SIZE);

    /*
     * mstatus: MPIE=1 (bit 7) so MIE is set after mret,
     *          MPP=3 (bits 12:11) to stay in machine mode.
     */
    frame[MRTOS_FRAME_MSTATUS] = (3u << 11) | (1u << 7);

    /* mepc: task entry point. */
    frame[MRTOS_FRAME_MEPC] = (uint32_t)(uintptr_t)entry;

    /* ra: task-exit sentinel so returning from entry is safe. */
    extern void mrtos_task_exit(void);
    frame[MRTOS_FRAME_RA] = (uint32_t)(uintptr_t)mrtos_task_exit;

    /* a0: first argument. */
    frame[MRTOS_FRAME_A0] = (uint32_t)(uintptr_t)arg;

    /*
     * gp (x3): global pointer set once by start.S to __global_pointer$.
     * If zeroed, every gp-relative global/static access by the task will
     * compute address 0+offset and fault immediately on first use.
     * Capture the current value — it is identical for all tasks.
     *
     * tp (x4): thread pointer; preserve for newlib re-entrancy if used.
     */
    uint32_t gp_val, tp_val;
    __asm__ volatile ("mv %0, gp" : "=r"(gp_val));
    __asm__ volatile ("mv %0, tp" : "=r"(tp_val));
    frame[MRTOS_FRAME_GP] = gp_val;
    frame[MRTOS_FRAME_TP] = tp_val;

    /* x2 (sp): the stack pointer that the task sees on first run.
     * It equals stack_top (empty task stack, nothing local yet). */
    frame[MRTOS_FRAME_SP] = (uint32_t)(top);

    return frame;
}

/* ════════════════════════════════════════════════════════════════════
 * Public API
 * ═══════════════════════════════════════════════════════════════════ */

void mrtos_init(void)
{
    memset(g_ready, 0, sizeof(g_ready));
    g_ready_mask             = 0u;
    g_current                = NULL;
    g_tick_count             = 0u;
    g_delayed_head           = NULL;
    mrtos_ctx_switch_pending = 0;
    mrtos_ctx_old_sp_ptr     = NULL;
    mrtos_ctx_new_sp         = NULL;
    mrtos_ctx_new_sguard_base = 0u;
    mrtos_ctx_new_spmin = 0xFFFFFFFFu;

    /* Create the idle task at the lowest possible priority. */
    mrtos_task_create(&g_idle_tcb, "idle", idle_task, NULL,
                      MRTOS_MAX_PRIORITY,        /* one level below user tasks */
                      g_idle_stack, sizeof(g_idle_stack));
}

void mrtos_task_create(mrtos_tcb_t *tcb,
                        const char  *name,
                        void       (*entry)(void *),
                        void        *arg,
                        uint8_t      priority,
                        void        *stack,
                        uint32_t     stack_size)
{
    if (priority > MRTOS_MAX_PRIORITY) {
        priority = MRTOS_MAX_PRIORITY;
    }

    tcb->name         = name;
    tcb->priority     = priority;
    tcb->eff_priority = priority;
    tcb->state        = MRTOS_TASK_READY;
    tcb->wake_tick    = 0u;
    tcb->next         = NULL;
    tcb->prev         = NULL;
    tcb->blocked_on   = NULL;
    tcb->sguard_base  = (uint32_t)(uintptr_t)stack;
    tcb->stack_top_addr = (uint32_t)((uintptr_t)stack + stack_size);
    tcb->spmin_saved  = tcb->stack_top_addr;

    /* Initialise the context frame at the top of the supplied stack. */
    uint8_t *top = (uint8_t *)stack + stack_size;
    tcb->sp = init_stack_frame(top, entry, arg);

    /* Add to the ready queue (critical section not needed yet before start). */
    uint32_t saved = mrtos_port_enter_critical();
    mrtos_ready_insert(tcb);
    mrtos_port_exit_critical(saved);
}

/**
 * @brief Called when a task function returns.
 *
 * Marks the task dead and yields so the scheduler picks another task.
 * The stack is NOT freed (no dynamic allocator).
 */
void mrtos_task_exit(void)
{
    uint32_t saved = mrtos_port_enter_critical();
    if (g_current != NULL) {
        g_current->state = MRTOS_TASK_DEAD;
        g_current        = NULL; /* Do not re-insert into ready queue. */
    }
    mrtos_port_exit_critical(saved);

    /* Force immediate reschedule. */
    mrtos_port_yield();

    /* Should never reach here. */
    while (1) {}
}

mrtos_tcb_t *mrtos_current_task(void)
{
    return g_current;
}

uint32_t mrtos_tick_count(void)
{
    return g_tick_count;
}

uint32_t mrtos_stack_watermark(const mrtos_tcb_t *tcb)
{
    if (tcb == NULL)
        return 0u;

    if (tcb->spmin_saved >= tcb->stack_top_addr)
        return 0u;

    return tcb->stack_top_addr - tcb->spmin_saved;
}

void mrtos_yield(void)
{
    uint32_t saved = mrtos_port_enter_critical();

    if (g_current != NULL) {
        /* Re-insert the current task at the tail of its priority queue. */
        g_current->state = MRTOS_TASK_READY;
        mrtos_ready_insert(g_current);

        /*
         * Arm the context switch while g_current still points to the
         * yielding task.  do_schedule() sets mrtos_ctx_old_sp_ptr to
         * &g_current->sp so the trap exit can save the frame.
         * Trigger the MSI inside the critical section (MIE=0) so the
         * interrupt is pending but cannot fire until after mret sets
         * MIE=1, preventing any race with a concurrent timer IRQ.
         */
        mrtos_request_switch();
        mrtos_port_yield(); /* MSIP set; fires after mrtos_port_exit_critical */
    }

    mrtos_port_exit_critical(saved);
}

void mrtos_delay(uint32_t ticks)
{
    if (ticks == 0u) {
        mrtos_yield();
        return;
    }

    uint32_t saved = mrtos_port_enter_critical();

    /* Move current task to delayed list. */
    if (g_current != NULL) {
        g_current->state     = MRTOS_TASK_DELAYED;
        g_current->wake_tick = g_tick_count + ticks;

        /* Insert into the delayed list (unsorted; scanned every tick). */
        g_current->next = g_delayed_head;
        g_current->prev = NULL;
        if (g_delayed_head != NULL) {
            g_delayed_head->prev = g_current;
        }
        g_delayed_head = g_current;

        /* Arm context switch while g_current still valid, then set MSIP
         * pending before re-enabling interrupts (no race with timer). */
        mrtos_request_switch();
        mrtos_port_yield();
    }

    mrtos_port_exit_critical(saved);
}

void mrtos_request_switch(void)
{
    do_schedule();
}

/**
 * @brief Called from the MSI handler to fix up yield with no available switch.
 *
 * If mrtos_yield() was called but do_schedule() found no higher-priority
 * task (the current task is the only one), the task is in the READY
 * state while still holding the CPU.  Restore it to RUNNING so the
 * tick handler does not see an inconsistent state.
 */
void mrtos_yield_msi_fixup(void)
{
    if (!mrtos_ctx_switch_pending
            && g_current != NULL
            && g_current->state == MRTOS_TASK_READY) {
        mrtos_ready_remove(g_current);
        g_current->state = MRTOS_TASK_RUNNING;
    }
}

/* ════════════════════════════════════════════════════════════════════
 * Tick handler — called from timer ISR (already in trap context)
 * ═══════════════════════════════════════════════════════════════════ */

void mrtos_tick(void)
{
    g_tick_count++;

    /* Wake delayed tasks whose deadline has passed. */
    mrtos_tcb_t *t = g_delayed_head;
    while (t != NULL) {
        mrtos_tcb_t *next_t = t->next; /* Save before potential list mutation. */
        if ((int32_t)(g_tick_count - t->wake_tick) >= 0) {
            /* Remove from delayed list. */
            if (t->prev != NULL) {
                t->prev->next = t->next;
            } else {
                g_delayed_head = t->next;
            }
            if (t->next != NULL) {
                t->next->prev = t->prev;
            }
            t->next = NULL;
            t->prev = NULL;

            /* Put back in ready queue. */
            t->state = MRTOS_TASK_READY;
            mrtos_ready_insert(t);
        }
        t = next_t;
    }

    /*
     * Round-robin: re-insert the running task at the tail of its queue
     * so that the next task at the same priority runs next tick.
     * do_schedule() will see state==READY and skip the duplicate re-insert,
     * but mrtos_ctx_old_sp_ptr still captures &g_current->sp correctly.
     */
    if (g_current != NULL && g_current->state == MRTOS_TASK_RUNNING) {
        g_current->state = MRTOS_TASK_READY;
        mrtos_ready_insert(g_current);
        /* DO NOT set g_current = NULL: do_schedule() needs it to fill
         * mrtos_ctx_old_sp_ptr so the trap exit saves the frame. */
    }

    /* Pick the next task and arm the context-switch variables. */
    do_schedule();
}

/* ════════════════════════════════════════════════════════════════════
 * mrtos_start
 * ═══════════════════════════════════════════════════════════════════ */

void mrtos_start(void)
{
    /* Install trap vector and start the CLINT tick timer. */
    mrtos_port_init();

    /* Pick the first task to run. */
    uint32_t saved = mrtos_port_enter_critical();
    mrtos_tcb_t *first = schedule_pick();
    mrtos_ready_remove(first);
    first->state = MRTOS_TASK_RUNNING;
    g_current    = first;
    write_csr_sguard_base(first->sguard_base);
    write_csr_spmin(first->spmin_saved);
    mrtos_port_exit_critical(saved);

    /* Hand off to the port; does not return. */
    mrtos_port_start_first(first->sp);
}
