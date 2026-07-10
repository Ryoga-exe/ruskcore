OUTPUT_ARCH("riscv")
ENTRY(_ruskcore_reset)

SECTIONS
{
  . = 0x00000000;
  .reset : { KEEP(*(.reset)) }

  . = 0x00001000;
  .tohost : { *(.tohost) }

  . = 0x00002000;
  .text.init : { *(.text.init) }

  . = ALIGN(0x1000);
  .text : { *(.text) }

  . = ALIGN(0x1000);
  .data : { *(.data) }
  .bss : { *(.bss) }
  _end = .;
}
