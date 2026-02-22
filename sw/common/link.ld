/* Linker script for RISC-V SoC */

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
        *(.text.init)
        *(.text*)
        *(.rodata*)
    } > RAM :text

    /* C++ initialization sections */
    .init : {
        KEEP (*(.init))
    } > RAM

    .fini : {
        KEEP (*(.fini))
    } > RAM

    .preinit_array : {
        PROVIDE_HIDDEN (__preinit_array_start = .);
        KEEP (*(.preinit_array*))
        PROVIDE_HIDDEN (__preinit_array_end = .);
    } > RAM

    .init_array : {
        PROVIDE_HIDDEN (__init_array_start = .);
        KEEP (*(SORT(.init_array.*)))
        KEEP (*(.init_array*))
        PROVIDE_HIDDEN (__init_array_end = .);
    } > RAM

    .fini_array : {
        PROVIDE_HIDDEN (__fini_array_start = .);
        KEEP (*(SORT(.fini_array.*)))
        KEEP (*(.fini_array*))
        PROVIDE_HIDDEN (__fini_array_end = .);
    } > RAM

    /* Exception handling */
    .eh_frame : {
        KEEP (*(.eh_frame))
    } > RAM

    .gcc_except_table : {
        *(.gcc_except_table .gcc_except_table.*)
    } > RAM

    .data : {
        _sdata = .;
        *(.data*)
        . = ALIGN(8);
        PROVIDE(__global_pointer$ = . + 0x800);
        *(.sdata*)
        _edata = .;
    } > RAM :data

    .bss : {
        _sbss = .;
        __bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        __bss_end = .;
        _ebss = .;
        . = ALIGN(8);
    } > RAM :data

    /* Host-Target Interface section for Spike compatibility */
    .tohost : ALIGN(8) {
        tohost = .;
        . += 8;
        fromhost = .;
        . += 8;
    } > RAM :data

    /* Reference to flash copy of data section - for ROM-based systems */
    _eronly = LOADADDR(.data) + SIZEOF(.data);

    /* Stack section - heap and stack share remaining memory */
    .stack : {
        . = ALIGN(16);
        __heap_start = .;
        /* Heap grows upward from here, stack grows downward from end of RAM */
    } > RAM

    /* Stack pointer initialized at end of RAM */
    __stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
