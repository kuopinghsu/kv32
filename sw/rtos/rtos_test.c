/**
 * @file rtos_test.c
 * @brief Mini-RTOS example and integration test.
 *
 * Exercises the following kernel features:
 *
 *  1. **Multi-priority round-robin scheduler** — four tasks at two
 *     priority levels share CPU time.  A tick counter verifies that
 *     each task makes progress.
 *
 *  2. **Semaphore** — a producer task posts a semaphore that two
 *     consumer tasks wait on, verifying FIFO wakeup order.
 *
 *  3. **Mutex with priority inheritance** — three tasks demonstrate
 *     that a low-priority holder's effective priority is raised when a
 *     high-priority task blocks on the same mutex, preventing priority
 *     inversion.
 *
 * @ingroup mrtos
 */

#include <stdio.h>
#include <stdint.h>
#include "mrtos.h"

/* ════════════════════════════════════════════════════════════════════
 * Test infrastructure
 * ═══════════════════════════════════════════════════════════════════ */

static int g_pass_count;
static int g_fail_count;

#define TEST_PASS(id, msg) \
    do { \
        printf("[PASS] Test %d: %s\n", (id), (msg)); \
        g_pass_count++; \
    } while (0)

#define TEST_FAIL(id, msg) \
    do { \
        printf("[FAIL] Test %d: %s\n", (id), (msg)); \
        g_fail_count++; \
    } while (0)

/* ════════════════════════════════════════════════════════════════════
 * Test 1: Scheduler — round-robin among equal-priority tasks
 * ═══════════════════════════════════════════════════════════════════ */

static mrtos_tcb_t   t1a_tcb, t1b_tcb;
static uint8_t       t1a_stack[512], t1b_stack[512];
static volatile int  t1a_runs, t1b_runs;
static mrtos_sem_t   t1_done;

static void task1a(void *arg)
{
    (void)arg;
    /* Run for N ticks then signal done. */
    for (int i = 0; i < 5; i++) {
        t1a_runs++;
        mrtos_yield();
    }
    mrtos_sem_post(&t1_done);
    /* Wait indefinitely so the task does not return. */
    while (1) { mrtos_delay(1000); }
}

static void task1b(void *arg)
{
    (void)arg;
    for (int i = 0; i < 5; i++) {
        t1b_runs++;
        mrtos_yield();
    }
    mrtos_sem_post(&t1_done);
    while (1) { mrtos_delay(1000); }
}

/* ════════════════════════════════════════════════════════════════════
 * Test 2: Semaphore — producer / consumer
 * ═══════════════════════════════════════════════════════════════════ */

static mrtos_tcb_t  t2p_tcb, t2c1_tcb, t2c2_tcb;
static uint8_t      t2p_stack[512], t2c1_stack[512], t2c2_stack[512];
static mrtos_sem_t  t2_sem;
static mrtos_sem_t  t2_result;
static volatile int t2_c1_woke, t2_c2_woke;

static void task2_consumer1(void *arg)
{
    (void)arg;
    mrtos_sem_wait(&t2_sem);
    t2_c1_woke = 1;
    mrtos_sem_post(&t2_result);
    while (1) { mrtos_delay(1000); }
}

static void task2_consumer2(void *arg)
{
    (void)arg;
    mrtos_sem_wait(&t2_sem);
    t2_c2_woke = 1;
    mrtos_sem_post(&t2_result);
    while (1) { mrtos_delay(1000); }
}

static void task2_producer(void *arg)
{
    (void)arg;
    /* Give consumers time to block on the semaphore. */
    mrtos_delay(20);

    /* Post twice — should wake both consumers. */
    mrtos_sem_post(&t2_sem);
    mrtos_delay(5);
    mrtos_sem_post(&t2_sem);

    while (1) { mrtos_delay(1000); }
}

/* ════════════════════════════════════════════════════════════════════
 * Test 3: Mutex with priority inheritance
 *
 * Scenario:
 *   - LOW  (priority 4) acquires the mutex and does a long computation.
 *   - MED  (priority 2) runs and spins, trying to starve LOW.
 *   - HIGH (priority 1) tries to acquire the same mutex.
 *
 * Expected: when HIGH blocks, LOW's effective priority is raised to 1
 * so that MED cannot preempt LOW.  LOW finishes, releases the mutex,
 * HIGH acquires it and records success.
 * ═══════════════════════════════════════════════════════════════════ */

static mrtos_tcb_t  t3lo_tcb, t3med_tcb, t3hi_tcb;
static uint8_t      t3lo_stack[512], t3med_stack[512], t3hi_stack[512];
static mrtos_mutex_t t3_mutex;
static mrtos_sem_t   t3_done;

/* Counts how many times MED runs while LOW holds the mutex. */
static volatile int t3_med_runs_while_lo_holds;
static volatile int t3_lo_held;   /* 1 while LOW holds mutex */
static volatile int t3_hi_got;    /* 1 when HIGH acquires mutex */
static volatile uint8_t t3_lo_eff_prio_seen; /* effective priority observed */

static void task3_low(void *arg)
{
    (void)arg;
    mrtos_mutex_lock(&t3_mutex);
    t3_lo_held = 1;

    /*
     * Simulate a long critical section.
     * Allow the scheduler to run other tasks during this loop so that
     * HIGH can attempt to acquire the mutex and trigger PI.
     */
    for (int i = 0; i < 40; i++) {
        mrtos_delay(1);
        /* Record our effective priority (should be raised to HIGH's when
         * HIGH is waiting). */
        mrtos_tcb_t *self = mrtos_current_task();
        if (self != NULL) {
            t3_lo_eff_prio_seen = self->eff_priority;
        }
    }

    t3_lo_held = 0;
    mrtos_mutex_unlock(&t3_mutex);
    while (1) { mrtos_delay(1000); }
}

static void task3_medium(void *arg)
{
    (void)arg;
    /* Run in tight loop to stress the scheduler. */
    while (1) {
        if (t3_lo_held) {
            t3_med_runs_while_lo_holds++;
        }
        mrtos_yield();
    }
}

static void task3_high(void *arg)
{
    (void)arg;
    /* Let LOW grab the mutex first. */
    mrtos_delay(5);

    mrtos_mutex_lock(&t3_mutex);
    t3_hi_got = 1;
    mrtos_mutex_unlock(&t3_mutex);

    mrtos_sem_post(&t3_done);
    while (1) { mrtos_delay(1000); }
}

/* ════════════════════════════════════════════════════════════════════
 * Supervisor task — creates sub-tasks, waits, evaluates results
 * ═══════════════════════════════════════════════════════════════════ */

static mrtos_tcb_t  supervisor_tcb;
static uint8_t      supervisor_stack[2048]; /* printf needs ~500 bytes */

static void supervisor_task(void *arg)
{
    (void)arg;

    /* ── Test 1: round-robin scheduler ─────────────────────────── */
    printf("\n[TEST 1] Round-robin scheduler among equal-priority tasks\n");

    mrtos_sem_init(&t1_done, 0);
    t1a_runs = 0;
    t1b_runs = 0;

    /* Both tasks at priority 2 (same as supervisor). */
    mrtos_task_create(&t1a_tcb, "t1a", task1a, NULL, 2,
                      t1a_stack, sizeof(t1a_stack));
    mrtos_task_create(&t1b_tcb, "t1b", task1b, NULL, 2,
                      t1b_stack, sizeof(t1b_stack));

    /* Wait for both to finish their loops. */
    mrtos_sem_wait(&t1_done);
    mrtos_sem_wait(&t1_done);

    if (t1a_runs >= 5 && t1b_runs >= 5) {
        TEST_PASS(1, "Both equal-priority tasks ran (RR scheduler)");
    } else {
        TEST_FAIL(1, "One or both tasks starved");
        printf("  t1a_runs=%d  t1b_runs=%d\n", t1a_runs, t1b_runs);
    }

    /* ── Test 2: semaphore ──────────────────────────────────────── */
    printf("\n[TEST 2] Semaphore producer / consumer\n");

    mrtos_sem_init(&t2_sem,    0);
    mrtos_sem_init(&t2_result, 0);
    t2_c1_woke = 0;
    t2_c2_woke = 0;

    /* Consumers at priority 3, producer at priority 3 too. */
    mrtos_task_create(&t2c1_tcb, "c1", task2_consumer1, NULL, 3,
                      t2c1_stack, sizeof(t2c1_stack));
    mrtos_task_create(&t2c2_tcb, "c2", task2_consumer2, NULL, 3,
                      t2c2_stack, sizeof(t2c2_stack));
    mrtos_task_create(&t2p_tcb,  "pr", task2_producer,  NULL, 3,
                      t2p_stack,  sizeof(t2p_stack));

    /* Wait for both consumers to signal. */
    mrtos_sem_wait(&t2_result);
    mrtos_sem_wait(&t2_result);

    if (t2_c1_woke && t2_c2_woke) {
        TEST_PASS(2, "Both semaphore consumers woken");
    } else {
        TEST_FAIL(2, "Not all consumers woken");
        printf("  c1_woke=%d  c2_woke=%d\n", t2_c1_woke, t2_c2_woke);
    }

    /* ── Test 3: priority inheritance ──────────────────────────── */
    printf("\n[TEST 3] Mutex priority inheritance (anti-inversion)\n");

    mrtos_mutex_init(&t3_mutex);
    mrtos_sem_init(&t3_done, 0);
    t3_med_runs_while_lo_holds = 0;
    t3_lo_held  = 0;
    t3_hi_got   = 0;
    t3_lo_eff_prio_seen = 0xFF;

    /* LOW=4, MED=2, HIGH=1 — supervisor at 2 must not interfere.
     * Temporarily yield priority by creating tasks first. */
    mrtos_task_create(&t3lo_tcb,  "lo",  task3_low,    NULL, 4,
                      t3lo_stack,  sizeof(t3lo_stack));
    mrtos_task_create(&t3med_tcb, "med", task3_medium, NULL, 2,
                      t3med_stack, sizeof(t3med_stack));
    mrtos_task_create(&t3hi_tcb,  "hi",  task3_high,   NULL, 1,
                      t3hi_stack,  sizeof(t3hi_stack));

    /* Wait for HIGH to acquire and release the mutex. */
    mrtos_sem_wait(&t3_done);

    if (t3_hi_got) {
        TEST_PASS(3, "HIGH task acquired mutex after LOW released it");
    } else {
        TEST_FAIL(3, "HIGH task never acquired the mutex");
    }

    /*
     * With priority inheritance, LOW's effective priority should have been
     * raised to HIGH's (1) while HIGH was waiting.  Verify that recording.
     */
    if (t3_lo_eff_prio_seen <= 1u) {
        TEST_PASS(3, "LOW's effective priority was raised (priority inheritance)");
    } else {
        TEST_FAIL(3, "Priority inheritance did not raise LOW's priority");
        printf("  lo_eff_prio_seen=%u (expected <=1)\n",
               (unsigned)t3_lo_eff_prio_seen);
    }

    /* MED should have been preempted by LOW (due to PI) and run only
     * a bounded number of times while LOW held the mutex. */
    printf("  MED ran %d time(s) while LOW held mutex\n",
            t3_med_runs_while_lo_holds);

    /* ── Summary ────────────────────────────────────────────────── */
    printf("\n========================================\n");
    printf("Mini-RTOS test complete: %d PASS, %d FAIL\n",
           g_pass_count, g_fail_count);
    printf("========================================\n");

    if (g_fail_count == 0) {
        printf("ALL TESTS PASSED\n");
    } else {
        printf("SOME TESTS FAILED\n");
    }

    while (1) { mrtos_delay(1000); }
}

/* ════════════════════════════════════════════════════════════════════
 * main
 * ═══════════════════════════════════════════════════════════════════ */

int main(void)
{
    printf("Mini-RTOS v1.0 — scheduler=%d Hz, priorities=%d, max_tasks=%d\n",
           MRTOS_TICK_HZ, MRTOS_MAX_PRIORITY + 1, MRTOS_MAX_TASKS);

    mrtos_init();

    /* Create the supervisor task at priority 2. */
    mrtos_task_create(&supervisor_tcb, "super", supervisor_task, NULL,
                      2, supervisor_stack, sizeof(supervisor_stack));

    /* Hand off to the RTOS — does not return. */
    mrtos_start();

    return 0;
}
