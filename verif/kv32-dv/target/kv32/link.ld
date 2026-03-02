/* ============================================================================
 * File: link.ld
 * Project: KV32 RISC-V Processor — riscv-dv target
 * Description: Linker script for riscv-dv generated random tests.
 *
 * Memory map matches the KV32 SoC:
 *   RAM: 0x8000_0000 – 0x801F_FFFF (2 MB)
 *
 * The generated assembly places _start at 0x8000_0000.  Data pages and
 * stack share the remaining address space.
 * ============================================================================ */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 2M
}

SECTIONS
{
    .text.init 0x80000000 : {
        *(.text.init)
    } > RAM

    . = ALIGN(4);

    .text : {
        *(.text*)
    } > RAM

    . = ALIGN(4);

    .rodata : {
        *(.rodata*)
    } > RAM

    . = ALIGN(4);

    .data : {
        *(.data*)
        *(.sdata*)
    } > RAM

    . = ALIGN(8);

    /* Host-Target Interface (tohost/fromhost) for Spike compatibility */
    .tohost : ALIGN(8) {
        tohost = .;
        . += 8;
        fromhost = .;
        . += 8;
    } > RAM

    . = ALIGN(4);

    .bss : {
        __bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        __bss_end = .;
    } > RAM

    /* Stack at end of RAM */
    __stack_top = ORIGIN(RAM) + LENGTH(RAM);

    /* Kernel and user virtual memory data pages used by riscv-dv */
    /* These symbols are referenced in the generated assembly header */
    _kernel_data_start = ALIGN(0x1000);
    _user_data_start   = _kernel_data_start + 0x10000;
}
