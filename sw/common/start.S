// Startup code for RISC-V processor
// Initializes stack, BSS, and calls main()

    .section .text.init
    .global _start
    .type _start, @function

_start:
    // Initialize global pointer
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop

    // Disable interrupts
    csrci mstatus, 0x8

    // Set up stack pointer
    la sp, __stack_top

    // Clear BSS section
    la a0, __bss_start
    la a1, __bss_end
    bgeu a0, a1, 2f
1:
    sw zero, 0(a0)
    addi a0, a0, 4
    bltu a0, a1, 1b
2:

    // Register global termination functions (if atexit exists)
    .weak   atexit
    la      a0, atexit
    beqz    a0, .Lweak_atexit
    .weak   __libc_fini_array
    la      a0, __libc_fini_array
    call    atexit
.Lweak_atexit:

    // Call newlib initialization (including constructors)
    call __libc_init_array

    // Set up trap vector
    la t0, trap_vector
    csrw mtvec, t0

    // Enable timer interrupt
    li t0, 0x80
    csrs mie, t0

    // Call main
    call main

    // Exit via newlib's exit function
    tail exit
    .size _start, .-_start

// DSO handle for dynamic shared object support
    .section .data
    .global __dso_handle
    .weak   __dso_handle
__dso_handle:
    .long   0

// Trap handler
    .section .text.init
    .align 4
trap_vector:
    // Save context
    addi sp, sp, -128
    sw x1, 4(sp)
    sw x2, 8(sp)
    sw x3, 12(sp)
    sw x4, 16(sp)
    sw x5, 20(sp)
    sw x6, 24(sp)
    sw x7, 28(sp)
    sw x8, 32(sp)
    sw x9, 36(sp)
    sw x10, 40(sp)
    sw x11, 44(sp)
    sw x12, 48(sp)
    sw x13, 52(sp)
    sw x14, 56(sp)
    sw x15, 60(sp)
    sw x16, 64(sp)
    sw x17, 68(sp)
    sw x18, 72(sp)
    sw x19, 76(sp)
    sw x20, 80(sp)
    sw x21, 84(sp)
    sw x22, 88(sp)
    sw x23, 92(sp)
    sw x24, 96(sp)
    sw x25, 100(sp)
    sw x26, 104(sp)
    sw x27, 108(sp)
    sw x28, 112(sp)
    sw x29, 116(sp)
    sw x30, 120(sp)
    sw x31, 124(sp)

    // Call C trap handler
    csrr a0, mcause
    csrr a1, mepc
    csrr a2, mtval
    call trap_handler

    // Restore context
    lw x1, 4(sp)
    lw x2, 8(sp)
    lw x3, 12(sp)
    lw x4, 16(sp)
    lw x5, 20(sp)
    lw x6, 24(sp)
    lw x7, 28(sp)
    lw x8, 32(sp)
    lw x9, 36(sp)
    lw x10, 40(sp)
    lw x11, 44(sp)
    lw x12, 48(sp)
    lw x13, 52(sp)
    lw x14, 56(sp)
    lw x15, 60(sp)
    lw x16, 64(sp)
    lw x17, 68(sp)
    lw x18, 72(sp)
    lw x19, 76(sp)
    lw x20, 80(sp)
    lw x21, 84(sp)
    lw x22, 88(sp)
    lw x23, 92(sp)
    lw x24, 96(sp)
    lw x25, 100(sp)
    lw x26, 104(sp)
    lw x27, 108(sp)
    lw x28, 112(sp)
    lw x29, 116(sp)
    lw x30, 120(sp)
    lw x31, 124(sp)
    addi sp, sp, 128

    mret
