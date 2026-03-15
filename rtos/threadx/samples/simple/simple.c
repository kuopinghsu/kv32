#include <stdio.h>
#include "tx_api.h"
#include "kv_platform.h"

#define SIMPLE_TEST_ITERATIONS  30u
#define SIMPLE_SLICE            1u
#define STACK_WORDS             256u
#define WAIT_TICKS              1000u

#define EVT_SWITCH_PING         (1u << 0)
#define EVT_SWITCH_ACK          (1u << 1)

static TX_THREAD thread_switch;
static TX_THREAD thread_semaphore;
static TX_THREAD thread_mutex;
static TX_THREAD thread_event;

static ULONG stack_switch[STACK_WORDS];
static ULONG stack_semaphore[STACK_WORDS];
static ULONG stack_mutex[STACK_WORDS];
static ULONG stack_event[STACK_WORDS];

static TX_SEMAPHORE g_test_semaphore;
static TX_MUTEX g_test_mutex;
static TX_EVENT_FLAGS_GROUP g_test_events;

static volatile ULONG g_shared_counter;
static volatile ULONG g_semaphore_takes;
static volatile ULONG g_mutex_ops;
static volatile ULONG g_event_acks;
static volatile ULONG g_completed_threads;

static void fail_and_exit(const char *reason)
{
    printf("[FAIL] %s\n", reason);
    kv_magic_exit(1);
    while (1) {
    }
}

static void finalize_if_done(void)
{
    ULONG done;
    ULONG expected_shared;
    TX_INTERRUPT_SAVE_AREA

    TX_DISABLE
    g_completed_threads++;
    done = g_completed_threads;
    TX_RESTORE

    if (done != 4u) {
        return;
    }

    expected_shared = SIMPLE_TEST_ITERATIONS * 2u;

    printf("\n=== ThreadX Simple Test Summary ===\n");
    printf("Iterations            : %lu\n", SIMPLE_TEST_ITERATIONS);
    printf("Semaphore takes       : %lu\n", g_semaphore_takes);
    printf("Mutex operations      : %lu\n", g_mutex_ops);
    printf("Event acknowledgements: %lu\n", g_event_acks);
    printf("Shared counter        : %lu (expected %lu)\n",
           g_shared_counter, expected_shared);

    if (g_semaphore_takes != SIMPLE_TEST_ITERATIONS ||
        g_mutex_ops != SIMPLE_TEST_ITERATIONS ||
        g_event_acks != SIMPLE_TEST_ITERATIONS ||
        g_shared_counter != expected_shared) {
        fail_and_exit("summary mismatch");
    }

    printf("[PASS] ThreadX switch/semaphore/mutex/event tests\n");
    kv_magic_exit(0);

    while (1) {
    }
}

static void thread_switch_entry(ULONG input)
{
    (void)input;

    for (ULONG i = 0; i < SIMPLE_TEST_ITERATIONS; ++i) {
        if (tx_mutex_get(&g_test_mutex, WAIT_TICKS) != TX_SUCCESS) {
            fail_and_exit("switch thread mutex get timeout");
        }
        g_shared_counter++;
        if (tx_mutex_put(&g_test_mutex) != TX_SUCCESS) {
            fail_and_exit("switch thread mutex put failed");
        }

        if (tx_semaphore_put(&g_test_semaphore) != TX_SUCCESS) {
            fail_and_exit("switch thread semaphore put failed");
        }

        if (tx_event_flags_set(&g_test_events, EVT_SWITCH_PING, TX_OR) != TX_SUCCESS) {
            fail_and_exit("switch thread event ping set failed");
        }

        ULONG actual_flags = 0u;
        if (tx_event_flags_get(&g_test_events, EVT_SWITCH_ACK,
                               TX_AND_CLEAR, &actual_flags, WAIT_TICKS) != TX_SUCCESS) {
            fail_and_exit("switch thread event ack timeout");
        }
        if ((actual_flags & EVT_SWITCH_ACK) == 0u) {
            fail_and_exit("switch thread ack bit missing");
        }

        tx_thread_relinquish();
    }

    printf("Switch thread complete\n");
    finalize_if_done();

    while (1) {
        tx_thread_sleep(1);
    }
}

static void thread_semaphore_entry(ULONG input)
{
    (void)input;

    for (ULONG i = 0; i < SIMPLE_TEST_ITERATIONS; ++i) {
        if (tx_semaphore_get(&g_test_semaphore, WAIT_TICKS) != TX_SUCCESS) {
            fail_and_exit("semaphore thread get timeout");
        }
        g_semaphore_takes++;
    }

    printf("Semaphore thread complete\n");
    finalize_if_done();

    while (1) {
        tx_thread_sleep(1);
    }
}

static void thread_mutex_entry(ULONG input)
{
    (void)input;

    for (ULONG i = 0; i < SIMPLE_TEST_ITERATIONS; ++i) {
        if (tx_mutex_get(&g_test_mutex, WAIT_TICKS) != TX_SUCCESS) {
            fail_and_exit("mutex thread get timeout");
        }
        g_shared_counter++;
        g_mutex_ops++;
        if (tx_mutex_put(&g_test_mutex) != TX_SUCCESS) {
            fail_and_exit("mutex thread put failed");
        }
        tx_thread_relinquish();
    }

    printf("Mutex thread complete\n");
    finalize_if_done();

    while (1) {
        tx_thread_sleep(1);
    }
}

static void thread_event_entry(ULONG input)
{
    (void)input;

    for (ULONG i = 0; i < SIMPLE_TEST_ITERATIONS; ++i) {
        ULONG actual_flags = 0u;
        if (tx_event_flags_get(&g_test_events, EVT_SWITCH_PING,
                               TX_AND_CLEAR, &actual_flags, WAIT_TICKS) != TX_SUCCESS) {
            fail_and_exit("event thread ping timeout");
        }
        if ((actual_flags & EVT_SWITCH_PING) == 0u) {
            fail_and_exit("event thread ping bit missing");
        }

        g_event_acks++;

        if (tx_event_flags_set(&g_test_events, EVT_SWITCH_ACK, TX_OR) != TX_SUCCESS) {
            fail_and_exit("event thread ack set failed");
        }

        tx_thread_relinquish();
    }

    printf("Event thread complete\n");
    finalize_if_done();

    while (1) {
        tx_thread_sleep(1);
    }
}

void tx_application_define(void *first_unused_memory)
{
    UINT status;

    (void)first_unused_memory;

    status = tx_semaphore_create(&g_test_semaphore, "sem", 0u);
    if (status != TX_SUCCESS) {
        fail_and_exit("semaphore create failed");
    }

    status = tx_mutex_create(&g_test_mutex, "mtx", TX_INHERIT);
    if (status != TX_SUCCESS) {
        fail_and_exit("mutex create failed");
    }

    status = tx_event_flags_create(&g_test_events, "evt");
    if (status != TX_SUCCESS) {
        fail_and_exit("event create failed");
    }

    status = tx_thread_create(&thread_switch, "switch", thread_switch_entry, 0,
                              stack_switch, sizeof(stack_switch),
                              3, 3, SIMPLE_SLICE, TX_AUTO_START);
    if (status != TX_SUCCESS) {
        fail_and_exit("switch thread create failed");
    }

    status = tx_thread_create(&thread_semaphore, "semaphore", thread_semaphore_entry, 0,
                              stack_semaphore, sizeof(stack_semaphore),
                              2, 2, SIMPLE_SLICE, TX_AUTO_START);
    if (status != TX_SUCCESS) {
        fail_and_exit("semaphore thread create failed");
    }

    status = tx_thread_create(&thread_mutex, "mutex", thread_mutex_entry, 0,
                              stack_mutex, sizeof(stack_mutex),
                              2, 2, SIMPLE_SLICE, TX_AUTO_START);
    if (status != TX_SUCCESS) {
        fail_and_exit("mutex thread create failed");
    }

    status = tx_thread_create(&thread_event, "event", thread_event_entry, 0,
                              stack_event, sizeof(stack_event),
                              2, 2, SIMPLE_SLICE, TX_AUTO_START);
    if (status != TX_SUCCESS) {
        fail_and_exit("event thread create failed");
    }
}

int main(void)
{
    printf("=== ThreadX KV32 simple 4-thread test ===\n");
    printf("Iterations : %lu\n", SIMPLE_TEST_ITERATIONS);

    tx_kernel_enter();

    fail_and_exit("tx_kernel_enter returned");
    return 1;
}
