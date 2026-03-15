#include <stdint.h>
#include "tx_api.h"
#include "tx_thread.h"
#include "tx_timer.h"
#include "kv_irq.h"
#include "kv_clint.h"
#include "kv_platform.h"

extern VOID *_tx_initialize_unused_memory;
extern VOID *_tx_thread_system_stack_ptr;
extern char __heap_start;
static void _tx_kv32_timer_irq(uint32_t cause);
static VOID _tx_kv32_stack_guard_init(TX_THREAD *thread_ptr);

VOID _tx_kv32_stack_guard_panic(TX_THREAD *thread_ptr)
{
    _tx_thread_stack_error_handler(thread_ptr);
    kv_magic_exit(1);
    while (1) {
    }
}

VOID _tx_timer_interrupt(VOID)
{
    _tx_thread_system_state++;

    _tx_timer_system_clock++;

    if (_tx_timer_time_slice != 0u) {
        _tx_timer_time_slice--;
        if (_tx_timer_time_slice == 0u) {
            _tx_timer_expired_time_slice = TX_TRUE;
        }
    }

    _tx_timer_expired = TX_TRUE;
    _tx_timer_expiration_process();

    if (_tx_timer_expired_time_slice == TX_TRUE) {
        _tx_thread_time_slice();
    }

    _tx_thread_system_state--;
}

UINT _tx_thread_interrupt_control(UINT new_posture)
{
    UINT old_posture;
    ULONG mstatus;

    __asm__ volatile("csrr %0, mstatus" : "=r"(mstatus));
    old_posture = (mstatus & 0x8u) ? TX_INT_ENABLE : TX_INT_DISABLE;

    if (new_posture == TX_INT_DISABLE) {
        __asm__ volatile("csrc mstatus, %0" :: "r"((ULONG)0x8u) : "memory");
    } else {
        __asm__ volatile("csrs mstatus, %0" :: "r"((ULONG)0x8u) : "memory");
    }

    return old_posture;
}

VOID _tx_initialize_low_level(VOID)
{
    ULONG sp;
    uintptr_t free_mem;

    __asm__ volatile("mv %0, sp" : "=r"(sp));
    _tx_thread_system_stack_ptr = (VOID *)sp;

    free_mem = (uintptr_t)&__heap_start;
    free_mem = (free_mem + 7u) & ~(uintptr_t)7u;
    _tx_initialize_unused_memory = (VOID *)free_mem;

    kv_irq_register(KV_CAUSE_MTI, _tx_kv32_timer_irq);
    kv_clint_timer_set_rel(TX_KV32_CLINT_CYCLES_PER_TICK);
    kv_clint_timer_irq_enable();
    kv_irq_enable();
}

VOID _tx_thread_stack_build(TX_THREAD *thread_ptr, VOID (*function_ptr)(VOID))
{
    ULONG *sp;
    uintptr_t top;
    ULONG gp;
    ULONG tp;

    __asm__ volatile("mv %0, gp" : "=r"(gp));
    __asm__ volatile("mv %0, tp" : "=r"(tp));

    _tx_kv32_stack_guard_init(thread_ptr);

    top = ((uintptr_t)thread_ptr->tx_thread_stack_end + 1u) & ~(uintptr_t)0xFu;
    sp = (ULONG *)(top - (31u * sizeof(ULONG)));

    for (UINT i = 0; i < 31u; i++) {
        sp[i] = 0u;
    }

    sp[0] = (ULONG)function_ptr;
    sp[1] = (ULONG)top;
    sp[2] = gp;
    sp[3] = tp;
    thread_ptr->tx_thread_stack_ptr = (VOID *)sp;
}

void trap_handler(kv_trap_frame_t *frame)
{
    uint32_t mcause;
    uint32_t cause;

    mcause = frame->mcause;
    cause = mcause & 0x7fffffffu;
    if ((mcause & 0x80000000u) != 0u) {
        if (cause == KV_CAUSE_MTI) {
            _tx_kv32_timer_irq(cause);

            if ((_tx_thread_current_ptr != TX_NULL) &&
                (_tx_thread_execute_ptr != TX_NULL) &&
                (_tx_thread_current_ptr != _tx_thread_execute_ptr) &&
                (_tx_thread_preempt_disable == 0u) &&
                (_tx_thread_system_state == 0u)) {
                frame->ra = frame->mepc;
                frame->mepc = (uint32_t)(uintptr_t)_tx_thread_system_return;
            }
            return;
        }
    } else if (cause == KV_EXC_STACK_OVERFLOW) {
        if (_tx_thread_current_ptr != TX_NULL) {
            _tx_kv32_stack_guard_panic(_tx_thread_current_ptr);
            return;
        }
    }

    kv_irq_dispatch(frame);
}

static void _tx_kv32_timer_irq(uint32_t cause)
{
    (void)cause;

    kv_clint_timer_set_rel(TX_KV32_CLINT_CYCLES_PER_TICK);
    _tx_timer_interrupt();
}

static VOID _tx_kv32_stack_guard_init(TX_THREAD *thread_ptr)
{
    ULONG *low_guard;
    ULONG *high_guard;

    low_guard = (ULONG *)thread_ptr->tx_thread_stack_start;
    high_guard = (ULONG *)((((UCHAR *)thread_ptr->tx_thread_stack_end) + 1u) - sizeof(ULONG));

    *low_guard = (ULONG)TX_STACK_FILL;
    *high_guard = (ULONG)TX_STACK_FILL;
}

