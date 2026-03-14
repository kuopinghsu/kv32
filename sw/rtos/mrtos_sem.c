/**
 * @file mrtos_sem.c
 * @brief Mini-RTOS counting semaphore.
 *
 * Tasks waiting on a semaphore are queued in FIFO order (the order in
 * which they called mrtos_sem_wait()).  mrtos_sem_post_from_isr() may
 * be called from any machine-mode interrupt handler; the context switch
 * is deferred to the trap-exit path so no yield is issued from the ISR.
 *
 * @ingroup mrtos
 */

#include <stddef.h>
#include "mrtos.h"
#include "mrtos_port.h"
#include "kv_irq.h"

/* Private helpers from mrtos_core.c */
extern void mrtos_ready_insert(mrtos_tcb_t *tcb);
extern void mrtos_request_switch(void);

/* ════════════════════════════════════════════════════════════════════
 * FIFO wait-list helpers
 * ═══════════════════════════════════════════════════════════════════ */

/** Append @p waiter at the tail of the FIFO wait list. */
static void fifo_push(mrtos_tcb_t **head, mrtos_tcb_t *waiter)
{
    waiter->next = NULL;
    if (*head == NULL) {
        *head = waiter;
        return;
    }
    mrtos_tcb_t *cur = *head;
    while (cur->next != NULL) {
        cur = cur->next;
    }
    cur->next = waiter;
}

/** Remove and return the front entry from the FIFO wait list. */
static mrtos_tcb_t *fifo_pop(mrtos_tcb_t **head)
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
 * Internal post helper (shared by post and post_from_isr)
 * ═══════════════════════════════════════════════════════════════════ */

/**
 * @brief Core post logic, called from a critical section.
 *
 * @return 1 if a context switch should be requested, 0 otherwise.
 */
static int sem_post_locked(mrtos_sem_t *s)
{
    mrtos_tcb_t *woken = fifo_pop(&s->waiters);
    if (woken != NULL) {
        /* Wake the front-of-queue task. */
        woken->state = MRTOS_TASK_READY;
        mrtos_ready_insert(woken);

        /* Request a switch if the woken task outranks the current one. */
        mrtos_tcb_t *cur = mrtos_current_task();
        if (cur == NULL || woken->eff_priority < cur->eff_priority) {
            return 1;
        }
    } else {
        s->count++;
    }
    return 0;
}

/* ════════════════════════════════════════════════════════════════════
 * Public API
 * ═══════════════════════════════════════════════════════════════════ */

void mrtos_sem_init(mrtos_sem_t *s, uint32_t initial_count)
{
    s->count   = initial_count;
    s->waiters = NULL;
}

void mrtos_sem_wait(mrtos_sem_t *s)
{
    uint32_t saved = mrtos_port_enter_critical();

    if (s->count > 0u) {
        /* Token available — consume it immediately. */
        s->count--;
        mrtos_port_exit_critical(saved);
        return;
    }

    /* Count is zero — block the calling task. */
    mrtos_tcb_t *self = mrtos_current_task();
    self->state = MRTOS_TASK_BLOCKED;
    fifo_push(&s->waiters, self);

    /* Schedule the next ready task and yield. */
    mrtos_request_switch();
    mrtos_port_exit_critical(saved);

    /*
     * Suspend here until sem_post_locked pulls us out of the waiters
     * queue and puts us back into the ready queue.  On single-core
     * there are no spurious wakeups, so no re-check is needed.
     * sem_post_locked transfers the token implicitly by waking the
     * task — no count increment happens for the waiter path.
     */
    mrtos_port_yield();
#if MRTOS_PORT_SEM_WAIT_WFI_SYNC
    /*
     * Spike can retire a few instructions after the MMIO write that raises
     * MSIP before it vectors into the trap handler.  For a blocking wait that
     * is fatal: the caller can fall through and observe the semaphore as if it
     * had been posted already.  Sleep in WFI until an interrupt boundary is
     * actually taken; when this task is rescheduled after sem_post_locked(),
     * execution resumes here and returns normally.
     */
    kv_wfi();
#endif
}

void mrtos_sem_post(mrtos_sem_t *s)
{
    uint32_t saved = mrtos_port_enter_critical();
    int need_switch = sem_post_locked(s);
    if (need_switch) {
        mrtos_request_switch();
    }
    mrtos_port_exit_critical(saved);

    if (need_switch) {
        mrtos_port_yield();
    }
}

void mrtos_sem_post_from_isr(mrtos_sem_t *s)
{
    /*
     * Called from inside the trap handler (already in a critical section
     * because interrupts are disabled in machine mode during trap handling).
     * Do not call enter/exit critical here — just do the work and let
     * mrtos_request_switch() set the pending flag for the trap-exit assembly.
     */
    int need_switch = sem_post_locked(s);
    if (need_switch) {
        mrtos_request_switch();
    }
}
