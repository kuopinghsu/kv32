OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 2M
}

PHDRS
{
  text  PT_LOAD FLAGS(5);  /* R + X */
  data  PT_LOAD FLAGS(6);  /* R + W */
}

SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) } :text
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) } :text
  . = ALIGN(0x1000);
  .text : { *(.text) } :text
  . = ALIGN(0x1000);
  .data : { *(.data) } :data
  .data.string : { *(.data.string)} :data
  .bss : { *(.bss) } :data
  _end = .;
}
