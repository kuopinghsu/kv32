/*
 * FreeRTOS Simple Test for RISC-V
 * Basic test to verify FreeRTOS scheduler and tasks
 */

#include "testcommon.h"
#include <stdio.h>
#include "FreeRTOS.h"
#include "task.h"
#include "semphr.h"

/* FreeRTOS hook functions */
void vApplicationIdleHook(void) {}
void vApplicationTickHook(void) {}
void vApplicationStackOverflowHook(TaskHandle_t xTask, char *pcTaskName) {
    (void)xTask;
    (void)pcTaskName;
    printf("Stack overflow in task: %s\n", pcTaskName);
    while(1);
}
void vApplicationMallocFailedHook(void) {
    printf("Malloc failed!\n");
    while(1);
}

/* Task functions */
void vTask1(void *pvParameters) {
    int count = 0;
    (void)pvParameters;

    for(;;) {
        printf("Task 1: %d\n", count++);

        /* Yield to other tasks instead of delay */
        for (volatile int i = 0; i < 100000; i++);
        taskYIELD();

        if (count >= 5) {
            printf("Task 1: Completed\n");
            vTaskDelete(NULL);
        }
    }
}

void vTask2(void *pvParameters) {
    int count = 0;
    (void)pvParameters;

    for(;;) {
        printf("Task 2: %d\n", count++);

        /* Yield to other tasks instead of delay */
        for (volatile int i = 0; i < 150000; i++);
        taskYIELD();

        if (count >= 3) {
            printf("Task 2: Completed\n");
            printf("\n=== FreeRTOS Test Complete ===\n");
            /* Exit simulation */
            volatile uint32_t *exit_reg = (volatile uint32_t *)0xFFFFFFF0;
            *exit_reg = 0;
            vTaskDelete(NULL);
        }
    }
}

void main(void) {
    printf("\n=== FreeRTOS Simple Test ===\n");
    printf("CPU Clock: %lu Hz\n", configCPU_CLOCK_HZ);
    printf("Tick Rate: %lu Hz\n", configTICK_RATE_HZ);
    printf("Heap Size: %zu bytes\n", configTOTAL_HEAP_SIZE);

    /* Create tasks */
    printf("Creating tasks...\n");

    if (xTaskCreate(vTask1, "Task1", configMINIMAL_STACK_SIZE * 2, NULL, 2, NULL) != pdPASS) {
        printf("Failed to create Task 1\n");
        return;
    }

    if (xTaskCreate(vTask2, "Task2", configMINIMAL_STACK_SIZE * 2, NULL, 2, NULL) != pdPASS) {
        printf("Failed to create Task 2\n");
        return;
    }

    printf("Starting scheduler...\n");

    /* Start the scheduler */
    vTaskStartScheduler();

    /* Should never reach here */
    printf("ERROR: Scheduler returned!\n");
    while(1);
}
