/*
 * Copyright (c) 2026 kv32 Project
 * SPDX-License-Identifier: Apache-2.0
 *
 * Zephyr simple 4-task test:
 *   1) task switch/yield
 *   2) semaphore give/take
 *   3) mutex lock/unlock
 *   4) event ping/ack
 */

#include <stdint.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include "kv_platform.h"

#define SIMPLE_TEST_ITERATIONS 10

#define STACK_SIZE      2048
#define THREAD_PRIORITY 7

#define EVT_TOKEN BIT(0)

K_SEM_DEFINE(g_test_sem, 0, SIMPLE_TEST_ITERATIONS);
K_MUTEX_DEFINE(g_test_mutex);
K_EVENT_DEFINE(g_ping_event);

static volatile uint32_t g_shared_counter;
static volatile uint32_t g_sem_takes;
static volatile uint32_t g_mutex_ops;
static volatile uint32_t g_event_acks;

K_THREAD_STACK_DEFINE(g_switch_stack, STACK_SIZE);
K_THREAD_STACK_DEFINE(g_sem_stack, STACK_SIZE);
K_THREAD_STACK_DEFINE(g_mutex_stack, STACK_SIZE);
K_THREAD_STACK_DEFINE(g_event_stack, STACK_SIZE);

static struct k_thread g_switch_thread;
static struct k_thread g_sem_thread;
static struct k_thread g_mutex_thread;
static struct k_thread g_event_thread;

static void fail_and_exit(const char *reason)
{
    printk("[FAIL] %s\n", reason);
    kv_magic_exit(1);
    while (1) {
    }
}

static void switch_task(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1);
    ARG_UNUSED(p2);
    ARG_UNUSED(p3);

    for (uint32_t i = 0; i < SIMPLE_TEST_ITERATIONS; i++) {
        if (k_mutex_lock(&g_test_mutex, K_FOREVER) != 0) {
            fail_and_exit("switch task mutex timeout");
        }
        g_shared_counter++;
        k_mutex_unlock(&g_test_mutex);

        k_sem_give(&g_test_sem);

        k_yield();
    }

    printk("Switch task complete\n");
}

static void semaphore_task(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1);
    ARG_UNUSED(p2);
    ARG_UNUSED(p3);

    for (uint32_t i = 0; i < SIMPLE_TEST_ITERATIONS; i++) {
        if (k_sem_take(&g_test_sem, K_FOREVER) != 0) {
            fail_and_exit("semaphore task timeout");
        }
        g_sem_takes++;
    }

    printk("Semaphore task complete\n");
}

static void mutex_task(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1);
    ARG_UNUSED(p2);
    ARG_UNUSED(p3);

    for (uint32_t i = 0; i < SIMPLE_TEST_ITERATIONS; i++) {
        if (k_mutex_lock(&g_test_mutex, K_FOREVER) != 0) {
            fail_and_exit("mutex task timeout");
        }
        g_shared_counter++;
        g_mutex_ops++;
        k_mutex_unlock(&g_test_mutex);
        k_yield();
    }

    printk("Mutex task complete\n");
}

static void event_task(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1);
    ARG_UNUSED(p2);
    ARG_UNUSED(p3);

    for (uint32_t i = 0; i < SIMPLE_TEST_ITERATIONS; i++) {
        uint32_t bits;

        (void)k_event_clear(&g_ping_event, EVT_TOKEN);
        k_event_post(&g_ping_event, EVT_TOKEN);
        bits = k_event_wait_safe(&g_ping_event, EVT_TOKEN, false, K_NO_WAIT);
        if ((bits & EVT_TOKEN) == 0U) {
            fail_and_exit("event task self-test failed");
        }
        g_event_acks++;
        k_yield();
    }

    printk("Event task complete\n");
}

int main(void)
{
    uint32_t expected_shared = SIMPLE_TEST_ITERATIONS * 2U;

    printk("\n=== Zephyr Simple 4-Task Test ===\n");
    printk("Iterations : %u\n", (unsigned)SIMPLE_TEST_ITERATIONS);

    k_tid_t switch_tid = k_thread_create(&g_switch_thread, g_switch_stack,
                                         K_THREAD_STACK_SIZEOF(g_switch_stack),
                                         switch_task,
                                         NULL, NULL, NULL,
                                         THREAD_PRIORITY, 0, K_NO_WAIT);
    k_tid_t sem_tid = k_thread_create(&g_sem_thread, g_sem_stack,
                                      K_THREAD_STACK_SIZEOF(g_sem_stack),
                                      semaphore_task,
                                      NULL, NULL, NULL,
                                      THREAD_PRIORITY, 0, K_NO_WAIT);
    k_tid_t mutex_tid = k_thread_create(&g_mutex_thread, g_mutex_stack,
                                        K_THREAD_STACK_SIZEOF(g_mutex_stack),
                                        mutex_task,
                                        NULL, NULL, NULL,
                                        THREAD_PRIORITY, 0, K_NO_WAIT);
    k_tid_t event_tid = k_thread_create(&g_event_thread, g_event_stack,
                                        K_THREAD_STACK_SIZEOF(g_event_stack),
                                        event_task,
                                        NULL, NULL, NULL,
                                        THREAD_PRIORITY, 0, K_NO_WAIT);

    k_thread_join(switch_tid, K_FOREVER);
    k_thread_join(sem_tid, K_FOREVER);
    k_thread_join(mutex_tid, K_FOREVER);
    k_thread_join(event_tid, K_FOREVER);

    printk("\n=== Zephyr Simple Test Summary ===\n");
    printk("Iterations            : %u\n", (unsigned)SIMPLE_TEST_ITERATIONS);
    printk("Semaphore takes       : %u\n", (unsigned)g_sem_takes);
    printk("Mutex operations      : %u\n", (unsigned)g_mutex_ops);
    printk("Event acknowledgements: %u\n", (unsigned)g_event_acks);
    printk("Shared counter        : %u (expected %u)\n",
           (unsigned)g_shared_counter, (unsigned)expected_shared);

    if (g_sem_takes != SIMPLE_TEST_ITERATIONS ||
        g_mutex_ops != SIMPLE_TEST_ITERATIONS ||
        g_event_acks != SIMPLE_TEST_ITERATIONS ||
        g_shared_counter != expected_shared) {
        fail_and_exit("summary mismatch");
    }

    printk("[PASS] basic switch/semaphore/mutex/event tests\n");
    kv_magic_exit(0);
    return 0;
}
