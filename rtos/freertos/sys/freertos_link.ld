/*
 * Linker script for FreeRTOS on RISC-V
 * Memory layout: 2MB RAM @ 0x80000000
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 2M
}

PHDRS
{
    text PT_LOAD FLAGS(5);  /* Read + Execute */
    data PT_LOAD FLAGS(6);  /* Read + Write */
}

SECTIONS
{
    .text : {
        KEEP(*(.text.init))
        *(.text.unlikely .text.unlikely.*)
        *(.text.startup .text.startup.*)
        *(.text .text.*)
        *(.gnu.linkonce.t.*)
    } > RAM :text

    .rodata : {
        *(.rdata)
        *(.rodata .rodata.*)
        *(.gnu.linkonce.r.*)
    } > RAM :text

    .data : {
        __data_start = .;
        *(.data .data.*)
        *(.gnu.linkonce.d.*)
        __data_end = .;
    } > RAM :data

    .sdata : {
        __global_pointer$ = . + 0x800;
        *(.srodata.cst16)
        *(.srodata.cst8)
        *(.srodata.cst4)
        *(.srodata.cst2)
        *(.srodata .srodata.*)
        *(.sdata .sdata.*)
        *(.gnu.linkonce.s.*)
    } > RAM :data

    .bss : {
        __bss_start = .;
        *(.sbss*)
        *(.gnu.linkonce.sb.*)
        *(.bss .bss.*)
        *(.gnu.linkonce.b.*)
        *(COMMON)
        __bss_end = .;
    } > RAM

    /* Stack grows downward */
    .stack (NOLOAD) : {
        . = ALIGN(16);
        __stack_bottom = .;
        . = . + 0x2000;  /* 8KB stack (reduced) */
        . = ALIGN(16);
        __stack_top = .;
    } > RAM

    /* FreeRTOS IRQ stack (if using separate IRQ stack) */
    .irq_stack (NOLOAD) : {
        . = ALIGN(16);
        __freertos_irq_stack_bottom = .;
        . = . + 0x800;  /* 2KB IRQ stack (reduced) */
        . = ALIGN(16);
        __freertos_irq_stack_top = .;
    } > RAM

    /* Heap for FreeRTOS */
    .heap (NOLOAD) : {
        . = ALIGN(16);
        __heap_start = .;
        . = ORIGIN(RAM) + LENGTH(RAM) - 0x100;
        . = ALIGN(16);
        __heap_end = .;
    } > RAM

    /* RISC-V test interface symbols */
    tohost = 0x80001000;
    fromhost = 0x80001040;

    _end = .;
}
