.text
.align 2

/* TX_THREAD critical section layout starts with:
 *   +0: tx_thread_id
 *   +4: tx_thread_run_count
 *   +8: tx_thread_stack_ptr
 */

/* Saved context frame on each thread stack (31 words):
 *   0:  ra
 *   1:  sp
 *   2:  gp
 *   3:  tp
 *   4:  t0
 *   5:  t1
 *   6:  t2
 *   7:  s0
 *   8:  s1
 *   9:  a0
 *  10:  a1
 *  11:  a2
 *  12:  a3
 *  13:  a4
 *  14:  a5
 *  15:  a6
 *  16:  a7
 *  17:  s2
 *  18:  s3
 *  19:  s4
 *  20:  s5
 *  21:  s6
 *  22:  s7
 *  23:  s8
 *  24:  s9
 *  25:  s10
 *  26:  s11
 *  27:  t3
 *  28:  t4
 *  29:  t5
 *  30:  t6
 */

.equ CTX_RA,   0
.equ CTX_SP,   4
.equ CTX_GP,   8
.equ CTX_TP,   12
.equ CTX_T0,   16
.equ CTX_T1,   20
.equ CTX_T2,   24
.equ CTX_S0,   28
.equ CTX_S1,   32
.equ CTX_A0,   36
.equ CTX_A1,   40
.equ CTX_A2,   44
.equ CTX_A3,   48
.equ CTX_A4,   52
.equ CTX_A5,   56
.equ CTX_A6,   60
.equ CTX_A7,   64
.equ CTX_S2,   68
.equ CTX_S3,   72
.equ CTX_S4,   76
.equ CTX_S5,   80
.equ CTX_S6,   84
.equ CTX_S7,   88
.equ CTX_S8,   92
.equ CTX_S9,   96
.equ CTX_S10,  100
.equ CTX_S11,  104
.equ CTX_T3,   108
.equ CTX_T4,   112
.equ CTX_T5,   116
.equ CTX_T6,   120
.equ CTX_SIZE, 124

/* KV32 custom CSR: stack guard base (sguard_base). */
.equ KV32_CSR_SGUARD_BASE, 0x7cc

.global _tx_thread_context_save
.type _tx_thread_context_save, @function
_tx_thread_context_save:
    j _tx_thread_system_return

.global _tx_thread_schedule
.type _tx_thread_schedule, @function
_tx_thread_schedule:
1:
    la t0, _tx_thread_execute_ptr
    lw t1, 0(t0)
    beqz t1, 1b
    la t0, _tx_thread_current_ptr
    sw t1, 0(t0)

.global _tx_thread_context_restore
.type _tx_thread_context_restore, @function
_tx_thread_context_restore:
    /* Program per-thread stack guard before switching to thread SP.
       Keep the low-end canary word outside the hardware fault region. */
    lw t0, 12(t1)
    csrw KV32_CSR_SGUARD_BASE, t0
    lw sp, 8(t1)
    lw ra, CTX_RA(sp)
    lw gp, CTX_GP(sp)
    lw tp, CTX_TP(sp)
    lw t0, CTX_T0(sp)
    lw t1, CTX_T1(sp)
    lw t2, CTX_T2(sp)
    lw s0, CTX_S0(sp)
    lw s1, CTX_S1(sp)
    lw a0, CTX_A0(sp)
    lw a1, CTX_A1(sp)
    lw a2, CTX_A2(sp)
    lw a3, CTX_A3(sp)
    lw a4, CTX_A4(sp)
    lw a5, CTX_A5(sp)
    lw a6, CTX_A6(sp)
    lw a7, CTX_A7(sp)
    lw s2, CTX_S2(sp)
    lw s3, CTX_S3(sp)
    lw s4, CTX_S4(sp)
    lw s5, CTX_S5(sp)
    lw s6, CTX_S6(sp)
    lw s7, CTX_S7(sp)
    lw s8, CTX_S8(sp)
    lw s9, CTX_S9(sp)
    lw s10, CTX_S10(sp)
    lw s11, CTX_S11(sp)
    lw t3, CTX_T3(sp)
    lw t4, CTX_T4(sp)
    lw t5, CTX_T5(sp)
    lw t6, CTX_T6(sp)
    lw sp, CTX_SP(sp)
    ret

.global _tx_thread_system_return
.type _tx_thread_system_return, @function
_tx_thread_system_return:
    csrci mstatus, 0x8

    addi sp, sp, -CTX_SIZE
    sw ra, CTX_RA(sp)
    sw gp, CTX_GP(sp)
    sw tp, CTX_TP(sp)
    sw t0, CTX_T0(sp)
    sw t1, CTX_T1(sp)
    sw t2, CTX_T2(sp)
    sw s0, CTX_S0(sp)
    sw s1, CTX_S1(sp)
    sw a0, CTX_A0(sp)
    sw a1, CTX_A1(sp)
    sw a2, CTX_A2(sp)
    sw a3, CTX_A3(sp)
    sw a4, CTX_A4(sp)
    sw a5, CTX_A5(sp)
    sw a6, CTX_A6(sp)
    sw a7, CTX_A7(sp)
    sw s2, CTX_S2(sp)
    sw s3, CTX_S3(sp)
    sw s4, CTX_S4(sp)
    sw s5, CTX_S5(sp)
    sw s6, CTX_S6(sp)
    sw s7, CTX_S7(sp)
    sw s8, CTX_S8(sp)
    sw s9, CTX_S9(sp)
    sw s10, CTX_S10(sp)
    sw s11, CTX_S11(sp)
    sw t3, CTX_T3(sp)
    sw t4, CTX_T4(sp)
    sw t5, CTX_T5(sp)
    sw t6, CTX_T6(sp)

    addi t0, sp, CTX_SIZE
    sw t0, CTX_SP(sp)

    la t0, _tx_thread_current_ptr
    lw t1, 0(t0)
    beqz t1, 1f
    sw sp, 8(t1)
    j 2f

1:
    addi sp, sp, CTX_SIZE

2:
3:
    la t0, _tx_thread_execute_ptr
    lw t1, 0(t0)
    beqz t1, 3b

    la t0, _tx_thread_current_ptr
    sw t1, 0(t0)

     /* Program per-thread stack guard before switching to thread SP.
         Keep the low-end canary word outside the hardware fault region. */
    lw t0, 12(t1)
     csrw KV32_CSR_SGUARD_BASE, t0
    lw sp, 8(t1)
    lw ra, CTX_RA(sp)
    lw gp, CTX_GP(sp)
    lw tp, CTX_TP(sp)
    lw t0, CTX_T0(sp)
    lw t1, CTX_T1(sp)
    lw t2, CTX_T2(sp)
    lw s0, CTX_S0(sp)
    lw s1, CTX_S1(sp)
    lw a0, CTX_A0(sp)
    lw a1, CTX_A1(sp)
    lw a2, CTX_A2(sp)
    lw a3, CTX_A3(sp)
    lw a4, CTX_A4(sp)
    lw a5, CTX_A5(sp)
    lw a6, CTX_A6(sp)
    lw a7, CTX_A7(sp)
    lw s2, CTX_S2(sp)
    lw s3, CTX_S3(sp)
    lw s4, CTX_S4(sp)
    lw s5, CTX_S5(sp)
    lw s6, CTX_S6(sp)
    lw s7, CTX_S7(sp)
    lw s8, CTX_S8(sp)
    lw s9, CTX_S9(sp)
    lw s10, CTX_S10(sp)
    lw s11, CTX_S11(sp)
    lw t3, CTX_T3(sp)
    lw t4, CTX_T4(sp)
    lw t5, CTX_T5(sp)
    lw t6, CTX_T6(sp)
    lw sp, CTX_SP(sp)
    csrsi mstatus, 0x8
    ret
