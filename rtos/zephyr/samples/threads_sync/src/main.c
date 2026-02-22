/*
 * Copyright (c) 2026 kcore Project
 * SPDX-License-Identifier: Apache-2.0
 *
 * Zephyr Thread Synchronization Test Sample
 * Demonstrates: Thread creation, Semaphores, Mutexes
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>

/* Thread stack sizes */
#define STACK_SIZE 512
#define THREAD_PRIORITY 7

/* Shared resource */
static int shared_counter = 0;

/* Synchronization primitives */
K_MUTEX_DEFINE(counter_mutex);
K_SEM_DEFINE(sem_producer, 0, 1);  /* Start at 0, max 1 */
K_SEM_DEFINE(sem_consumer, 0, 1);

/* Thread stacks */
K_THREAD_STACK_DEFINE(producer_stack, STACK_SIZE);
K_THREAD_STACK_DEFINE(consumer_stack, STACK_SIZE);
K_THREAD_STACK_DEFINE(worker1_stack, STACK_SIZE);
K_THREAD_STACK_DEFINE(worker2_stack, STACK_SIZE);
K_THREAD_STACK_DEFINE(worker3_stack, STACK_SIZE);

/* Thread control blocks */
static struct k_thread producer_thread;
static struct k_thread consumer_thread;
static struct k_thread worker1_thread;
static struct k_thread worker2_thread;
static struct k_thread worker3_thread;

/* Thread IDs */
static k_tid_t producer_tid;
static k_tid_t consumer_tid;
static k_tid_t worker1_tid;
static k_tid_t worker2_tid;
static k_tid_t worker3_tid;

void sim_exit(int exit_code)
{
    /* Write to exit magic address */
    *((volatile uint32_t *)0xFFFFFFF0) = exit_code;
}

/* Producer thread - signals consumer via semaphore */
void producer_entry(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1);
    ARG_UNUSED(p2);
    ARG_UNUSED(p3);

    printk("Producer thread started\n");

    for (int i = 0; i < 5; i++) {
        k_msleep(100);

        /* Produce data */
        k_mutex_lock(&counter_mutex, K_FOREVER);
        shared_counter++;
        printk("Producer: produced item %d, counter = %d\n", i + 1, shared_counter);
        k_mutex_unlock(&counter_mutex);

        /* Signal consumer that data is ready */
        k_sem_give(&sem_consumer);

        /* Wait for consumer to finish processing */
        k_sem_take(&sem_producer, K_FOREVER);
    }

    printk("Producer thread completed\n");
}

/* Consumer thread - waits for producer signal */
void consumer_entry(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1);
    ARG_UNUSED(p2);
    ARG_UNUSED(p3);

    printk("Consumer thread started\n");

    for (int i = 0; i < 5; i++) {
        /* Wait for producer signal */
        k_sem_take(&sem_consumer, K_FOREVER);

        /* Consume data */
        k_mutex_lock(&counter_mutex, K_FOREVER);
        printk("Consumer: consumed item, counter = %d\n", shared_counter);
        k_mutex_unlock(&counter_mutex);

        k_msleep(50);

        /* Signal producer to continue */
        k_sem_give(&sem_producer);
    }

    printk("Consumer thread completed\n");
}

/* Worker threads - compete for mutex-protected resource */
void worker_entry(void *p1, void *p2, void *p3)
{
    int worker_id = (int)(uintptr_t)p1;
    ARG_UNUSED(p2);
    ARG_UNUSED(p3);

    printk("Worker %d thread started\n", worker_id);

    for (int i = 0; i < 3; i++) {
        k_msleep(50 + (worker_id * 20));

        /* Critical section protected by mutex */
        k_mutex_lock(&counter_mutex, K_FOREVER);

        int old_value = shared_counter;
        k_busy_wait(10000);  /* Simulate work - 10ms */
        shared_counter = old_value + 1;

        printk("Worker %d: incremented counter from %d to %d (iteration %d)\n",
               worker_id, old_value, shared_counter, i + 1);

        k_mutex_unlock(&counter_mutex);

        k_msleep(30);
    }

    printk("Worker %d thread completed\n", worker_id);
}

int main(void)
{
    printk("\n*** Zephyr Thread Synchronization Test ***\n\n");

    /* Test 1: Producer-Consumer with Semaphores */
    printk("=== Test 1: Producer-Consumer Pattern ===\n");
    shared_counter = 0;

    producer_tid = k_thread_create(&producer_thread, producer_stack,
                                    K_THREAD_STACK_SIZEOF(producer_stack),
                                    producer_entry,
                                    NULL, NULL, NULL,
                                    THREAD_PRIORITY, 0, K_NO_WAIT);

    consumer_tid = k_thread_create(&consumer_thread, consumer_stack,
                                    K_THREAD_STACK_SIZEOF(consumer_stack),
                                    consumer_entry,
                                    NULL, NULL, NULL,
                                    THREAD_PRIORITY, 0, K_NO_WAIT);

    /* Wait for producer-consumer to complete */
    k_thread_join(producer_tid, K_FOREVER);
    k_thread_join(consumer_tid, K_FOREVER);

    printk("Producer-Consumer test completed. Final counter: %d\n\n", shared_counter);

    /* Small delay between tests */
    k_msleep(200);

    /* Test 2: Multiple Workers with Mutex */
    printk("=== Test 2: Multiple Workers with Mutex ===\n");
    shared_counter = 0;

    worker1_tid = k_thread_create(&worker1_thread, worker1_stack,
                                   K_THREAD_STACK_SIZEOF(worker1_stack),
                                   worker_entry,
                                   (void *)1, NULL, NULL,
                                   THREAD_PRIORITY, 0, K_NO_WAIT);

    worker2_tid = k_thread_create(&worker2_thread, worker2_stack,
                                   K_THREAD_STACK_SIZEOF(worker2_stack),
                                   worker_entry,
                                   (void *)2, NULL, NULL,
                                   THREAD_PRIORITY, 0, K_NO_WAIT);

    worker3_tid = k_thread_create(&worker3_thread, worker3_stack,
                                   K_THREAD_STACK_SIZEOF(worker3_stack),
                                   worker_entry,
                                   (void *)3, NULL, NULL,
                                   THREAD_PRIORITY, 0, K_NO_WAIT);

    /* Wait for all workers to complete */
    k_thread_join(worker1_tid, K_FOREVER);
    k_thread_join(worker2_tid, K_FOREVER);
    k_thread_join(worker3_tid, K_FOREVER);

    printk("Multiple workers test completed. Final counter: %d\n", shared_counter);
    printk("Expected counter value: 9 (3 workers × 3 increments)\n\n");

    /* Verify results */
    if (shared_counter == 9) {
        printk("*** Thread Synchronization Test PASSED ***\n");
        printk("All threads synchronized correctly!\n");
    } else {
        printk("*** Thread Synchronization Test FAILED ***\n");
        printk("Counter mismatch! Got %d, expected 9\n", shared_counter);
    }

    printk("\nTest complete. Exiting...\n");
    sim_exit(0);
    return 0;
}
