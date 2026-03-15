/*
 * FreeRTOS Simple Test for RISC-V
 * Basic 4-task validation:
 *   1) Task switch/yield
 *   2) Semaphore give/take
 *   3) Mutex lock/unlock on shared state
 *   4) Event-group ping/ack
 */

#include "testcommon.h"
#include <stdio.h>
#include "FreeRTOS.h"
#include "task.h"
#include "semphr.h"
#include "event_groups.h"

/* Number of iterations per test path. */
#define SIMPLE_TEST_ITERATIONS 30

#define EVT_SWITCH_PING (1U << 0)
#define EVT_SWITCH_ACK  (1U << 1)

static SemaphoreHandle_t gTestSemaphore;
static SemaphoreHandle_t gTestMutex;
static EventGroupHandle_t gTestEvents;

static volatile uint32_t gSharedCounter;
static volatile uint32_t gSemaphoreTakes;
static volatile uint32_t gMutexOps;
static volatile uint32_t gEventAcks;
static volatile uint32_t gCompletedTasks;

static void fail_and_exit(const char *reason)
{
    printf("[FAIL] %s\n", reason);
    kv_magic_exit(1);
    while (1) {
    }
}

static void finalize_if_done(void)
{
    uint32_t done;

    taskENTER_CRITICAL();
    gCompletedTasks++;
    done = gCompletedTasks;
    taskEXIT_CRITICAL();

    if (done == 4U) {
        uint32_t expectedShared = SIMPLE_TEST_ITERATIONS * 2U;
        printf("\n=== FreeRTOS Simple Test Summary ===\n");
        printf("Iterations            : %u\n", (unsigned)SIMPLE_TEST_ITERATIONS);
        printf("Semaphore takes       : %u\n", (unsigned)gSemaphoreTakes);
        printf("Mutex operations      : %u\n", (unsigned)gMutexOps);
        printf("Event acknowledgements: %u\n", (unsigned)gEventAcks);
        printf("Shared counter        : %u (expected %u)\n",
               (unsigned)gSharedCounter, (unsigned)expectedShared);

        if (gSemaphoreTakes != SIMPLE_TEST_ITERATIONS ||
            gMutexOps != SIMPLE_TEST_ITERATIONS ||
            gEventAcks != SIMPLE_TEST_ITERATIONS ||
            gSharedCounter != expectedShared) {
            fail_and_exit("summary mismatch");
        }

        printf("[PASS] basic switch/semaphore/mutex/event tests\n");
        kv_magic_exit(0);
    }
}

/* FreeRTOS hook functions */
void vApplicationIdleHook(void) {}
void vApplicationTickHook(void) {}
void vApplicationStackOverflowHook(TaskHandle_t xTask, char *pcTaskName)
{
    (void)xTask;
    printf("Stack overflow in task: %s\n", pcTaskName);
    kv_magic_exit(1);
    while (1) {
    }
}
void vApplicationMallocFailedHook(void)
{
    printf("Malloc failed!\n");
    kv_magic_exit(1);
    while (1) {
    }
}

static void vSwitchTask(void *pvParameters)
{
    (void)pvParameters;

    for (uint32_t i = 0; i < SIMPLE_TEST_ITERATIONS; i++) {
        if (xSemaphoreTake(gTestMutex, pdMS_TO_TICKS(1000)) != pdTRUE) {
            fail_and_exit("switch task mutex take timeout");
        }
        gSharedCounter++;
        xSemaphoreGive(gTestMutex);

        if (xSemaphoreGive(gTestSemaphore) != pdTRUE) {
            fail_and_exit("switch task semaphore give failed");
        }

        xEventGroupSetBits(gTestEvents, EVT_SWITCH_PING);
        EventBits_t bits = xEventGroupWaitBits(
            gTestEvents,
            EVT_SWITCH_ACK,
            pdTRUE,
            pdTRUE,
            pdMS_TO_TICKS(1000));
        if ((bits & EVT_SWITCH_ACK) == 0U) {
            fail_and_exit("switch task event ack timeout");
        }

        taskYIELD();
    }

    printf("Switch task complete\n");
    finalize_if_done();
    vTaskDelete(NULL);
}

static void vSemaphoreTask(void *pvParameters)
{
    (void)pvParameters;

    for (uint32_t i = 0; i < SIMPLE_TEST_ITERATIONS; i++) {
        if (xSemaphoreTake(gTestSemaphore, pdMS_TO_TICKS(1000)) != pdTRUE) {
            fail_and_exit("semaphore task take timeout");
        }
        gSemaphoreTakes++;
    }

    printf("Semaphore task complete\n");
    finalize_if_done();
    vTaskDelete(NULL);
}

static void vMutexTask(void *pvParameters)
{
    (void)pvParameters;

    for (uint32_t i = 0; i < SIMPLE_TEST_ITERATIONS; i++) {
        if (xSemaphoreTake(gTestMutex, pdMS_TO_TICKS(1000)) != pdTRUE) {
            fail_and_exit("mutex task take timeout");
        }
        gSharedCounter++;
        gMutexOps++;
        xSemaphoreGive(gTestMutex);
        taskYIELD();
    }

    printf("Mutex task complete\n");
    finalize_if_done();
    vTaskDelete(NULL);
}

static void vEventTask(void *pvParameters)
{
    (void)pvParameters;

    for (uint32_t i = 0; i < SIMPLE_TEST_ITERATIONS; i++) {
        EventBits_t bits = xEventGroupWaitBits(
            gTestEvents,
            EVT_SWITCH_PING,
            pdTRUE,
            pdTRUE,
            pdMS_TO_TICKS(1000));
        if ((bits & EVT_SWITCH_PING) == 0U) {
            fail_and_exit("event task ping timeout");
        }
        gEventAcks++;
        xEventGroupSetBits(gTestEvents, EVT_SWITCH_ACK);
    }

    printf("Event task complete\n");
    finalize_if_done();
    vTaskDelete(NULL);
}

void main(void)
{
    printf("\n=== FreeRTOS Simple 4-Task Test ===\n");
    printf("CPU Clock  : %lu Hz\n", configCPU_CLOCK_HZ);
    printf("Tick Rate  : %lu Hz\n", configTICK_RATE_HZ);
    printf("Heap Size  : %zu bytes\n", configTOTAL_HEAP_SIZE);
    printf("Iterations : %u\n", (unsigned)SIMPLE_TEST_ITERATIONS);

    gTestSemaphore = xSemaphoreCreateBinary();
    gTestMutex = xSemaphoreCreateMutex();
    gTestEvents = xEventGroupCreate();
    if (gTestSemaphore == NULL || gTestMutex == NULL || gTestEvents == NULL) {
        fail_and_exit("object creation failed");
    }

    if (xTaskCreate(vSwitchTask, "SwTask", configMINIMAL_STACK_SIZE * 2U, NULL, 3, NULL) != pdPASS) {
        fail_and_exit("create switch task failed");
    }
    if (xTaskCreate(vSemaphoreTask, "SemTask", configMINIMAL_STACK_SIZE * 2U, NULL, 2, NULL) != pdPASS) {
        fail_and_exit("create semaphore task failed");
    }
    if (xTaskCreate(vMutexTask, "MutTask", configMINIMAL_STACK_SIZE * 2U, NULL, 2, NULL) != pdPASS) {
        fail_and_exit("create mutex task failed");
    }
    if (xTaskCreate(vEventTask, "EvtTask", configMINIMAL_STACK_SIZE * 2U, NULL, 2, NULL) != pdPASS) {
        fail_and_exit("create event task failed");
    }

    printf("Starting scheduler...\n");
    vTaskStartScheduler();

    fail_and_exit("scheduler returned unexpectedly");
}
