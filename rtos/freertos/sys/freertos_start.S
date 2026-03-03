/*
 * FreeRTOS RISC-V Startup Code
 * Entry point and basic initialization
 */

.section .text.init
.global _start
.type _start, @function

_start:
    /* Disable interrupts */
    csrw mie, zero
    csrw mip, zero

    /* Initialize global pointer */
.option push
.option norelax
    la gp, __global_pointer$
.option pop

    /* Initialize stack pointer */
    la sp, __stack_top

    /* Clear BSS */
    la a0, __bss_start
    la a1, __bss_end
    bgeu a0, a1, 2f
1:
    sw zero, 0(a0)
    addi a0, a0, 4
    bltu a0, a1, 1b
2:

    /* Set up trap vector */
    la t0, freertos_risc_v_trap_handler
    csrw mtvec, t0

    /* Enable timer and software interrupts */
    li t0, 0x880  /* MIE bit + MTIE + MSIE */
    csrw mie, t0

    /* Jump to main */
    call main

    /* If main returns, exit */
    li a0, 0
    j _exit

.size _start, .-_start

/* Exit handler */
.global _exit
.extern tohost
.type _exit, @function
_exit:
    /* Write exit code to magic address */
    li t0, 0x40000004
    sw a0, 0(t0)
    li t0, 1
1:
    j 1b  /* Infinite loop */
.size _exit, .-_exit

/* Weak trap handler (can be overridden by FreeRTOS) */
.weak freertos_risc_v_trap_handler
.type freertos_risc_v_trap_handler, @function
freertos_risc_v_trap_handler:
    j freertos_risc_v_trap_handler
.size freertos_risc_v_trap_handler, .-freertos_risc_v_trap_handler
