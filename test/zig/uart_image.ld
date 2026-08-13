OUTPUT_ARCH( "riscv" )
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 8K
}

SECTIONS
{
  .text.init : { KEEP(*(.text.init)) } > RAM
  .text : { *(.text*) } > RAM
  .rodata : { *(.rodata*) } > RAM
  .data : { *(.data*) } > RAM
  .bss (NOLOAD) : { *(.bss*) } > RAM
  .stack (NOLOAD) : {
    . = ALIGN(0x10);
    _stack_bottom = .;
    . += 1K;
    _stack_top = .;
  } > RAM
  _end = .;

  /DISCARD/ : {
    *(.eh_frame*)
    *(.comment*)
  }
}
