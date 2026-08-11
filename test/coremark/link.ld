OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text.init : { KEEP(*(.text.init)) }
  .text : { *(.text*) }
  .rodata : { *(.rodata*) }
  .data : { *(.data*) }
  .bss : { *(.bss*) *(COMMON) }
  .stack : {
    . = ALIGN(0x10);
    _stack_bottom = .;
    . += 64K;
    _stack_top = .;
  }
  _end = .;

  /DISCARD/ : {
    *(.eh_frame*)
    *(.comment*)
  }
}
