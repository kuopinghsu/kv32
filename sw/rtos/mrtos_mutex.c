/**
 * @file mrtos_mutex.c
 * @brief Mini-RTOS mutex with priority inheritance.
 *
 * ### Priority inheritance protocol
 *
 * Priority inversion occurs when a high-priority task H is blocked
 * waiting for a mutex held by a low-priority task L, while a medium-
 * priority task M preempts L and delays L indefinitely.
 *
 * This implementation prevents unbounded priority inversion by raising
 * the effective priority of the mutex owner to at least the priority of
 * the highest-priority waiter.  The chain is propagated transitively:
 * if L is itself blocked on another mutex, its owner also inherits.
 *
 * When the mutex is released the owner's effective priority is
 * recomputed from the highest-priority task still waiting for mutexes
 * it holds (simplified here: restored to base priority).
 *
 * @ingroup mrtos
 */

#include <stddef.h>
#include "mrtos.h"
#include "mrtos_port.h"

extern volatile int mrtos_ctx_switch_pending;

/* Private helpers declared in mrtos_core.c */
extern void mrtos_ready_insert(mrtos_tcb_t *tcb);
extern void mrtos_ready_remove(mrtos_tcb_t *tcb);
extern void mrtos_request_switch(void);

/* ════════════════════════════════════════════════════════════════════
 * Wait-list helpers (single-linked, priority-ordered)
 * ═══════════════════════════════════════════════════════════════════ */

/**
 * @brief Insert @p waiter into a singly-linked wait list in ascending
 *        effective-priority order (lowest numeric value = highest priority
 *        = front of list).
 */
static void waitlist_insert(mrtos_tcb_t **head, mrtos_tcb_t *waiter)
{
    waiter->next = NULL;

    if (*head == NULL || waiter->eff_priority < (*head)->eff_priority) {
        waiter->next = *head;
        *head        = waiter;
        return;
    }

    mrtos_tcb_t *cur = *head;
    while (cur->next != NULL &&
           cur->next->eff_priority <= waiter->eff_priority) {
        cur = cur->next;
    }
    waiter->next = cur->next;
    cur->next    = waiter;
}

/**
 * @brief Remove and return the first entry from a singly-linked wait list.
 */
static mrtos_tcb_t *waitlist_pop(mrtos_tcb_t **head)
{
    if (*head == NULL) {
        return NULL;
    }
    mrtos_tcb_t *first = *head;
    *head = first->next;
    first->next = NULL;
    return first;
}

/* ════════════════════════════════════════════════════════════════════
 * Priority inheritance propagation
 * ═══════════════════════════════════════════════════════════════════ */

/**
 * @brief Propagate an inherited priority @p new_prio up the mutex-chain
 *        starting at @p holder.
 *
 * Walks the chain: if holder is itself blocked on another mutex, the
 * same inheritance is applied to that mutex's owner, etc.
 * Must be called from a critical section.
 */
static void propagate_pi(mrtos_tcb_t *holder, uint8_t new_prio)
{
    while (holder != NULL && new_prio < holder->eff_priority) {
        if (holder->state == MRTOS_TASK_READY) {
            /* Re-insert at the new (higher) priority. */
            mrtos_ready_remove(holder);
            holder->eff_priority = new_prio;
            mrtos_ready_insert(holder);
        } else if (holder->state == MRTOS_TASK_RUNNING) {
            holder->eff_priority = new_prio;
        } else {
            /* BLOCKED or DELAYED: just update the field. */
            holder->eff_priority = new_prio;
        }

        /* Walk up the chain if holder is also blocked. */
        mrtos_mutex_t *m = holder->blocked_on;
        if (m == NULL || m->owner == NULL) {
            break;
        }
        holder = m->owner;
    }
}

/* ════════════════════════════════════════════════════════════════════
 * Public API
 * ═══════════════════════════════════════════════════════════════════ */

void mrtos_mutex_init(mrtos_mutex_t *m)
{
    m->owner   = NULL;
    m->waiters = NULL;
}

void mrtos_mutex_lock(mrtos_mutex_t *m)
{
    while (1) {
        uint32_t saved = mrtos_port_enter_critical();

        if (m->owner == NULL) {
            /* Mutex is free — take it immediately. */
            m->owner = mrtos_current_task();
            mrtos_port_exit_critical(saved);
            return;
        }

        /* Mutex is held by another task.  Block and apply PI. */
        mrtos_tcb_t *self   = mrtos_current_task();
        mrtos_tcb_t *owner  = m->owner;

        /* Record what we are blocked on. */
        self->blocked_on = m;
        self->state      = MRTOS_TASK_BLOCKED;

        /* Insert into the mutex wait list (priority-ordered). */
        waitlist_insert(&m->waiters, self);

        /*
         * Priority inheritance: if we have a higher priority than the
         * current owner, raise the owner's effective priority.
         */
        if (self->eff_priority < owner->eff_priority) {
            propagate_pi(owner, self->eff_priority);
        }

        /* Re-schedule (do not re-insert self — it is BLOCKED). */
        mrtos_request_switch();
        mrtos_port_exit_critical(saved);

        /* Trigger the context switch via software interrupt. */
        mrtos_port_yield();

        /*
         * When we wake up (mutex was unlocked and we were the highest-
         * priority waiter), loop back and attempt to take the mutex again.
         * This handles the spurious-wakeup case and the scenario where
         * another task acquired the mutex before us.
         */
    }
}

void mrtos_mutex_unlock(mrtos_mutex_t *m)
{
    uint32_t saved = mrtos_port_enter_critical();

    mrtos_tcb_t *self = mrtos_current_task();

    /* Restore owner's effective priority to its base priority.
     * A more complete implementation would scan all owned mutexes and
     * set eff_priority to max(base, highest waiter across all mutexes). */
    if (self != NULL && self->eff_priority != self->priority) {
        if (self->state == MRTOS_TASK_RUNNING) {
            self->eff_priority = self->priority;
        } else if (self->state == MRTOS_TASK_READY) {
            mrtos_ready_remove(self);
            self->eff_priority = self->priority;
            mrtos_ready_insert(self);
        } else {
            self->eff_priority = self->priority;
        }
    }

    m->owner = NULL;

    /* Wake the highest-priority waiter. */
    mrtos_tcb_t *woken = waitlist_pop(&m->waiters);
    if (woken != NULL) {
        woken->blocked_on = NULL;
        woken->state      = MRTOS_TASK_READY;
        mrtos_ready_insert(woken);

        /* If the woken task has higher priority than the current task,
         * request a context switch. */
        mrtos_tcb_t *cur = mrtos_current_task();
        if (cur == NULL || woken->eff_priority < cur->eff_priority) {
            mrtos_request_switch();
        }
    }

    mrtos_port_exit_critical(saved);

    /* Yield only if a higher-priority task was woken. */
    if (mrtos_ctx_switch_pending) {
        mrtos_port_yield();
    }
}
