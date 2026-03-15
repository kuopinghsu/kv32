#include <stdint.h>
#include <stdio.h>

#include "tx_api.h"
#include "kv_platform.h"

#define STACK_WORDS              320u
#define CTRL_PRIORITY            3u
#define WORKER_PRIORITY          8u
#define SIMPLE_SLICE             1u

#define BASIC_ARRAY_WORDS        128u
#define BASIC_ITERATIONS         20u

#define PREEMPT_WINDOW_TICKS     10u
#define SYNC_ITERATIONS          100u

#define WAIT_TICKS               5000u

static TX_THREAD g_ctrl_thread;
static TX_THREAD g_preempt_a_thread;
static TX_THREAD g_preempt_b_thread;
static TX_THREAD g_sync_giver_thread;
static TX_THREAD g_sync_taker_thread;

static ULONG g_ctrl_stack[STACK_WORDS];
static ULONG g_preempt_a_stack[STACK_WORDS];
static ULONG g_preempt_b_stack[STACK_WORDS];
static ULONG g_sync_giver_stack[STACK_WORDS];
static ULONG g_sync_taker_stack[STACK_WORDS];

static TX_SEMAPHORE g_preempt_start;
static TX_SEMAPHORE g_preempt_done;
static TX_SEMAPHORE g_preempt_ready;
static TX_SEMAPHORE g_sync_start;
static TX_SEMAPHORE g_sync_done;
static TX_SEMAPHORE g_sync_ping;
static TX_SEMAPHORE g_sync_pong;

static volatile ULONG g_basic_counter;
static volatile ULONG g_basic_array[BASIC_ARRAY_WORDS];

static volatile ULONG g_preempt_count_a;
static volatile ULONG g_preempt_count_b;
static volatile UINT g_preempt_running;

static volatile ULONG g_sync_give_count;
static volatile ULONG g_sync_take_count;
static volatile ULONG g_sync_target;
static volatile UINT g_sync_running;

static uint64_t g_basic_ticks;
static uint64_t g_preempt_ticks;
static uint64_t g_sync_ticks;

static void fail_and_exit(const char *reason)
{
    printf("[FAIL] %s\n", reason);
    kv_magic_exit(1);
    while (1) {
    }
}

static void check_status(UINT status, const char *reason)
{
    if (status != TX_SUCCESS) {
        printf("[FAIL] %s (status=%u)\n", reason, (unsigned)status);
        fail_and_exit(reason);
    }
}

static void print_metric(const char *name, uint64_t ticks, uint64_t ops)
{
    uint64_t ops_per_tick_q100;

    if (ops == 0u) {
        printf("%s: invalid operation count\n", name);
        return;
    }

    if (ticks == 0u) {
        ticks = 1u;
    }

    ops_per_tick_q100 = (ops * 100u) / ticks;

    printf("%s\n", name);
    printf("  operations : %llu\n", (unsigned long long)ops);
    printf("  ticks      : %llu\n", (unsigned long long)ticks);
    printf("  ops/tick   : %lu.%02lu\n",
           (unsigned long)(ops_per_tick_q100 / 100u),
           (unsigned long)(ops_per_tick_q100 % 100u));
}

static void preempt_a_entry(ULONG input)
{
    (void)input;

    while (1) {
        check_status(tx_semaphore_get(&g_preempt_start, TX_WAIT_FOREVER), "preempt A start wait failed");

        g_preempt_count_a++;
        check_status(tx_semaphore_put(&g_preempt_ready), "preempt A ready signal failed");

        while (g_preempt_running != 0u) {
            g_preempt_count_a++;
        }

        check_status(tx_semaphore_put(&g_preempt_done), "preempt A done signal failed");
    }
}

static void preempt_b_entry(ULONG input)
{
    (void)input;

    while (1) {
        check_status(tx_semaphore_get(&g_preempt_start, TX_WAIT_FOREVER), "preempt B start wait failed");

        g_preempt_count_b++;
        check_status(tx_semaphore_put(&g_preempt_ready), "preempt B ready signal failed");

        while (g_preempt_running != 0u) {
            g_preempt_count_b++;
        }

        check_status(tx_semaphore_put(&g_preempt_done), "preempt B done signal failed");
    }
}

static void sync_giver_entry(ULONG input)
{
    (void)input;

    while (1) {
        check_status(tx_semaphore_get(&g_sync_start, TX_WAIT_FOREVER), "sync giver start wait failed");

        g_sync_give_count = 0u;
        while (g_sync_give_count < g_sync_target) {
            check_status(tx_semaphore_put(&g_sync_ping), "sync giver ping put failed");
            check_status(tx_semaphore_get(&g_sync_pong, WAIT_TICKS), "sync giver pong wait failed");
            g_sync_give_count++;
        }

        g_sync_running = 0u;
        check_status(tx_semaphore_put(&g_sync_ping), "sync giver release ping failed");
        check_status(tx_semaphore_put(&g_sync_done), "sync giver done signal failed");
    }
}

static void sync_taker_entry(ULONG input)
{
    (void)input;

    while (1) {
        check_status(tx_semaphore_get(&g_sync_start, TX_WAIT_FOREVER), "sync taker start wait failed");

        g_sync_take_count = 0u;
        while (1) {
            check_status(tx_semaphore_get(&g_sync_ping, WAIT_TICKS), "sync taker ping wait failed");
            if (g_sync_running == 0u) {
                break;
            }
            g_sync_take_count++;
            check_status(tx_semaphore_put(&g_sync_pong), "sync taker pong put failed");
        }
    }
}

static void run_basic_processing(void)
{
    uint64_t start;
    uint64_t end;

    for (ULONG i = 0; i < BASIC_ARRAY_WORDS; ++i) {
        g_basic_array[i] = i;
    }

    g_basic_counter = 0u;
    start = (uint64_t)tx_time_get();

    for (ULONG it = 0; it < BASIC_ITERATIONS; ++it) {
        for (ULONG i = 0; i < BASIC_ARRAY_WORDS; ++i) {
            g_basic_array[i] = (g_basic_array[i] + g_basic_counter) ^ (i + 0x9e37u);
        }
        g_basic_counter++;
    }

    end = (uint64_t)tx_time_get();
    g_basic_ticks = end - start;
}

static void run_preempt_benchmark(void)
{
    uint64_t start;
    uint64_t end;

    g_preempt_count_a = 0u;
    g_preempt_count_b = 0u;
    g_preempt_running = 1u;

    start = (uint64_t)tx_time_get();
    check_status(tx_semaphore_put(&g_preempt_start), "preempt start A failed");
    check_status(tx_semaphore_put(&g_preempt_start), "preempt start B failed");
    check_status(tx_semaphore_get(&g_preempt_ready, WAIT_TICKS), "preempt ready wait A failed");
    check_status(tx_semaphore_get(&g_preempt_ready, WAIT_TICKS), "preempt ready wait B failed");
    check_status(tx_thread_sleep(PREEMPT_WINDOW_TICKS), "preempt window sleep failed");
    g_preempt_running = 0u;

    check_status(tx_semaphore_get(&g_preempt_done, WAIT_TICKS), "preempt done wait A failed");
    check_status(tx_semaphore_get(&g_preempt_done, WAIT_TICKS), "preempt done wait B failed");
    end = (uint64_t)tx_time_get();

    g_preempt_ticks = end - start;

    if (g_preempt_count_a == 0u || g_preempt_count_b == 0u) {
        fail_and_exit("preempt counters did not advance");
    }
}

static void run_sync_benchmark(void)
{
    uint64_t start;
    uint64_t end;

    g_sync_target = SYNC_ITERATIONS;
    g_sync_running = 1u;

    start = (uint64_t)tx_time_get();
    check_status(tx_semaphore_put(&g_sync_start), "sync start giver failed");
    check_status(tx_semaphore_put(&g_sync_start), "sync start taker failed");
    check_status(tx_semaphore_get(&g_sync_done, WAIT_TICKS), "sync done wait failed");
    end = (uint64_t)tx_time_get();

    g_sync_ticks = end - start;

    if (g_sync_give_count != SYNC_ITERATIONS || g_sync_take_count != SYNC_ITERATIONS) {
        fail_and_exit("sync counters mismatch");
    }
}

static void controller_entry(ULONG input)
{
    (void)input;

    printf("=== ThreadX KV32 benchmark (Thread-Metric style) ===\n");
    printf("basic iterations   : %lu\n", (unsigned long)BASIC_ITERATIONS);
    printf("preempt ticks      : %lu\n", (unsigned long)PREEMPT_WINDOW_TICKS);
    printf("sync iterations    : %lu\n", (unsigned long)SYNC_ITERATIONS);

    printf("[INFO] run basic\n");
    run_basic_processing();

    printf("[INFO] run preempt\n");
    run_preempt_benchmark();

    printf("[INFO] run sync\n");
    run_sync_benchmark();

    printf("\n=== Benchmark Summary ===\n");
    print_metric("tm_basic-like processing", g_basic_ticks,
                 (uint64_t)BASIC_ITERATIONS * (uint64_t)BASIC_ARRAY_WORDS);
    print_metric("tm_preempt-like scheduling", g_preempt_ticks,
                 (uint64_t)g_preempt_count_a + (uint64_t)g_preempt_count_b);
    print_metric("tm_sync-like semaphore", g_sync_ticks,
                 (uint64_t)g_sync_give_count + (uint64_t)g_sync_take_count);

    printf("[PASS] ThreadX benchmark sample\n");
    kv_magic_exit(0);

    while (1) {
    }
}

void tx_application_define(void *first_unused_memory)
{
    UINT status;

    (void)first_unused_memory;

    status = tx_semaphore_create(&g_preempt_start, "preempt_start", 0u);
    check_status(status, "preempt start semaphore create failed");
    status = tx_semaphore_create(&g_preempt_done, "preempt_done", 0u);
    check_status(status, "preempt done semaphore create failed");
    status = tx_semaphore_create(&g_preempt_ready, "preempt_ready", 0u);
    check_status(status, "preempt ready semaphore create failed");
    status = tx_semaphore_create(&g_sync_start, "sync_start", 0u);
    check_status(status, "sync start semaphore create failed");
    status = tx_semaphore_create(&g_sync_done, "sync_done", 0u);
    check_status(status, "sync done semaphore create failed");
    status = tx_semaphore_create(&g_sync_ping, "sync_ping", 0u);
    check_status(status, "sync ping semaphore create failed");
    status = tx_semaphore_create(&g_sync_pong, "sync_pong", 0u);
    check_status(status, "sync pong semaphore create failed");

    status = tx_thread_create(&g_ctrl_thread, "ctrl", controller_entry, 0,
                              g_ctrl_stack, sizeof(g_ctrl_stack),
                              CTRL_PRIORITY, CTRL_PRIORITY, SIMPLE_SLICE, TX_AUTO_START);
    check_status(status, "controller thread create failed");

    status = tx_thread_create(&g_preempt_a_thread, "preempt_a", preempt_a_entry, 0,
                              g_preempt_a_stack, sizeof(g_preempt_a_stack),
                              WORKER_PRIORITY, WORKER_PRIORITY, SIMPLE_SLICE, TX_AUTO_START);
    check_status(status, "preempt A thread create failed");

    status = tx_thread_create(&g_preempt_b_thread, "preempt_b", preempt_b_entry, 0,
                              g_preempt_b_stack, sizeof(g_preempt_b_stack),
                              WORKER_PRIORITY, WORKER_PRIORITY, SIMPLE_SLICE, TX_AUTO_START);
    check_status(status, "preempt B thread create failed");

    status = tx_thread_create(&g_sync_giver_thread, "sync_giver", sync_giver_entry, 0,
                              g_sync_giver_stack, sizeof(g_sync_giver_stack),
                              WORKER_PRIORITY + 1u, WORKER_PRIORITY + 1u, SIMPLE_SLICE, TX_AUTO_START);
    check_status(status, "sync giver thread create failed");

    status = tx_thread_create(&g_sync_taker_thread, "sync_taker", sync_taker_entry, 0,
                              g_sync_taker_stack, sizeof(g_sync_taker_stack),
                              WORKER_PRIORITY + 1u, WORKER_PRIORITY + 1u, SIMPLE_SLICE, TX_AUTO_START);
    check_status(status, "sync taker thread create failed");
}

int main(void)
{
    printf("=== ThreadX benchmark sample ===\n");
    tx_kernel_enter();

    fail_and_exit("tx_kernel_enter returned");
    return 1;
}
