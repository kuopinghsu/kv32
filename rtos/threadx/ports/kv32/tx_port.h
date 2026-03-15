#ifndef TX_PORT_H
#define TX_PORT_H

#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TX_PORT_SPECIFIC_PRE_SCHEDULER_INITIALIZATION
#define TX_PORT_THREAD_STACK_ERROR_HANDLING

typedef void VOID;
typedef char CHAR;
typedef unsigned char UCHAR;
typedef int INT;
typedef unsigned int UINT;
typedef long LONG;
typedef unsigned long ULONG;
typedef short SHORT;
typedef unsigned short USHORT;

#define TX_MAX_PRIORITIES              32
#define TX_MINIMUM_STACK               256
#define TX_TIMER_THREAD_STACK_SIZE     1024
#define TX_TIMER_THREAD_PRIORITY       0
#define TX_TIMER_TICKS_PER_SECOND      100

#ifndef TX_KV32_CLINT_CYCLES_PER_TICK
#define TX_KV32_CLINT_CYCLES_PER_TICK  100000ULL
#endif

#define TX_INT_DISABLE                 1u
#define TX_INT_ENABLE                  0u

#define TX_THREAD_EXTENSION_0
#define TX_THREAD_EXTENSION_1
#define TX_THREAD_EXTENSION_2
#define TX_THREAD_EXTENSION_3
#define TX_THREAD_EXTENSION
#define TX_THREAD_USER_EXTENSION
#define TX_BLOCK_POOL_EXTENSION
#define TX_BYTE_POOL_EXTENSION
#define TX_EVENT_FLAGS_GROUP_EXTENSION
#define TX_MUTEX_EXTENSION
#define TX_QUEUE_EXTENSION
#define TX_SEMAPHORE_EXTENSION
#define TX_TIMER_EXTENSION
#define TX_TIMER_INTERNAL_EXTENSION

#define TX_INITIALIZE_KERNEL_ENTER_EXTENSION
#define TX_TRACE_PORT_EXTENSION
#define TX_THREAD_CREATE_EXTENSION(t)
#define TX_THREAD_DELETE_EXTENSION(t)
#define TX_THREAD_STARTED_EXTENSION(t)
#define TX_THREAD_COMPLETED_EXTENSION(t)
#define TX_THREAD_TERMINATED_EXTENSION(t)
#define TX_THREAD_STACK_ANALYZE_EXTENSION
#define TX_BLOCK_POOL_CREATE_EXTENSION(b)
#define TX_BLOCK_POOL_DELETE_EXTENSION(b)
#define TX_BYTE_POOL_CREATE_EXTENSION(b)
#define TX_BYTE_POOL_DELETE_EXTENSION(b)
#define TX_BYTE_ALLOCATE_EXTENSION
#define TX_BYTE_RELEASE_EXTENSION
#define TX_EVENT_FLAGS_GROUP_CREATE_EXTENSION(g)
#define TX_EVENT_FLAGS_GROUP_DELETE_EXTENSION(g)
#define TX_MUTEX_CREATE_EXTENSION(m)
#define TX_MUTEX_DELETE_EXTENSION(m)
#define TX_MUTEX_PRIORITY_CHANGE_EXTENSION
#define TX_MUTEX_PUT_EXTENSION(m)
#define TX_MUTEX_PRIORITIZE_MISRA_EXTENSION
#define TX_QUEUE_CREATE_EXTENSION(q)
#define TX_QUEUE_DELETE_EXTENSION(q)
#define TX_SEMAPHORE_CREATE_EXTENSION(s)
#define TX_SEMAPHORE_DELETE_EXTENSION(s)
#define TX_TIMER_CREATE_EXTENSION(t)
#define TX_TIMER_DELETE_EXTENSION(t)
#define TX_TIMER_INITIALIZE_EXTENSION(status) TX_PARAMETER_NOT_USED(status);

#define TX_INTERRUPT_SAVE_AREA         UINT interrupt_save;
#define TX_DISABLE                     interrupt_save = _tx_thread_interrupt_control(TX_INT_DISABLE);
#define TX_RESTORE                     _tx_thread_interrupt_control(interrupt_save);

#define TX_INLINE_INITIALIZATION       1

#ifdef TX_INCLUDE_USER_DEFINE_FILE
#include "tx_user.h"
#endif

UINT _tx_thread_interrupt_control(UINT new_posture);

#ifdef __cplusplus
}
#endif

#endif
