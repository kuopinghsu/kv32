/*
 * FreeRTOS Kernel V11.2.0
 * Configuration for RISC-V RV32IMAC Core
 */

#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

/*-----------------------------------------------------------
 * Application specific definitions.
 *
 * These definitions should be adjusted for your particular hardware and
 * application requirements.
 *
 * THESE PARAMETERS ARE DESCRIBED WITHIN THE 'CONFIGURATION' SECTION OF THE
 * FreeRTOS API DOCUMENTATION AVAILABLE ON THE FreeRTOS.org WEB SITE.
 *
 * See http://www.freertos.org/a00110.html
 *----------------------------------------------------------*/

/* Prevent C code being included in assembly code */
#if !defined(__ASSEMBLER__)
extern uint64_t read_csr_cycle64(void);
#define configGET_CORE_CLOCK_HZ()   100000000UL  /* 100 MHz */
#endif

#define configUSE_PREEMPTION                    1
#define configUSE_IDLE_HOOK                     0
#define configUSE_TICK_HOOK                     0
#define configCPU_CLOCK_HZ                      ( 100000000UL )  /* 100 MHz */
#define configTICK_RATE_HZ                      ( ( TickType_t ) 1000 )  /* 1 ms tick */
#define configSUPPORT_STATIC_ALLOCATION         0
#define configSUPPORT_DYNAMIC_ALLOCATION        1
#define configMAX_PRIORITIES                    ( 8 )
#define configMINIMAL_STACK_SIZE                ( ( unsigned short ) 512 )
#define configTOTAL_HEAP_SIZE                   ( ( size_t ) ( 64 * 1024 ) )  /* 64KB heap */
#define configMAX_TASK_NAME_LEN                 ( 16 )
#define configUSE_TRACE_FACILITY                0
#define configUSE_16_BIT_TICKS                  0
#define configIDLE_SHOULD_YIELD                 0
#define configUSE_MUTEXES                       1
#define configQUEUE_REGISTRY_SIZE               8
#define configCHECK_FOR_STACK_OVERFLOW          0
#define configUSE_RECURSIVE_MUTEXES             1
#define configUSE_MALLOC_FAILED_HOOK            1
#define configUSE_APPLICATION_TASK_TAG          0
#define configUSE_COUNTING_SEMAPHORES           1
#define configGENERATE_RUN_TIME_STATS           0
#define configUSE_PORT_OPTIMISED_TASK_SELECTION 0
#define configUSE_TICKLESS_IDLE                 0

/* Co-routine definitions. */
#define configUSE_CO_ROUTINES                   0
#define configMAX_CO_ROUTINE_PRIORITIES         ( 2 )

/* Software timer definitions. */
#define configUSE_TIMERS                        1
#define configTIMER_TASK_PRIORITY               ( configMAX_PRIORITIES - 1 )
#define configTIMER_QUEUE_LENGTH                10
#define configTIMER_TASK_STACK_DEPTH            ( configMINIMAL_STACK_SIZE * 2 )

/* Event group definitions */
#define configUSE_EVENT_GROUPS                  1

/* Stream buffer and message buffer */
#define configUSE_STREAM_BUFFERS                1

/* Task function prototypes required by RISC-V port */
#define configUSE_TASK_NOTIFICATIONS            1
#define configUSE_TASK_FPU_SUPPORT              0

/* Set the following definitions to 1 to include the API function, or zero
to exclude the API function. */
#define INCLUDE_vTaskPrioritySet                1
#define INCLUDE_uxTaskPriorityGet               1
#define INCLUDE_vTaskDelete                     1
#define INCLUDE_vTaskCleanUpResources           1
#define INCLUDE_vTaskSuspend                    1
#define INCLUDE_vTaskDelayUntil                 1
#define INCLUDE_vTaskDelay                      1
#define INCLUDE_xTaskGetSchedulerState          1
#define INCLUDE_xTimerPendFunctionCall          1
#define INCLUDE_xTaskAbortDelay                 1
#define INCLUDE_xTaskGetHandle                  1
#define INCLUDE_xTaskResumeFromISR              1

/* RISC-V specific definitions */
#define configMTIME_BASE_ADDRESS                ( 0x0200BFF8UL )  /* CLINT mtime @ 0x0200BFF8 */
#define configMTIMECMP_BASE_ADDRESS             ( 0x02004000UL )  /* CLINT mtimecmp @ 0x02004000 */

/* ISR stack size in words (optional - can use main stack) */
#define configISR_STACK_SIZE_WORDS              ( 256 )

/* Assertions */
#define configASSERT( x ) if( ( x ) == 0 ) { taskDISABLE_INTERRUPTS(); for( ;; ); }

/* RISC-V privilege mode */
#define configMTIME_UNIT_SIZE                   8  /* 64-bit mtime */

/* SMP/Multi-core settings (single core for now) */
#define configNUMBER_OF_CORES                   1
#define configUSE_CORE_AFFINITY                 0

/* RISC-V port specific configuration */
#define configKERNEL_INTERRUPT_PRIORITY         0

#endif /* FREERTOS_CONFIG_H */
