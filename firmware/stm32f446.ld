/* STM32F446RE: 512 KB flash @ 0x08000000, 128 KB SRAM @ 0x20000000. */
ENTRY(Reset_Handler)
_estack = 0x20020000;   /* top of 128 KB SRAM */

MEMORY
{
  FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 512K
  RAM   (rwx) : ORIGIN = 0x20000000, LENGTH = 128K
}

SECTIONS
{
  .isr_vector : { KEEP(*(.isr_vector)) } > FLASH

  .text : {
    *(.text*)
    *(.rodata*)
  } > FLASH

  _sidata = LOADADDR(.data);
  .data : {
    _sdata = .;
    *(.data*)
    _edata = .;
  } > RAM AT > FLASH

  .bss : {
    _sbss = .;
    *(.bss*)
    *(COMMON)
    _ebss = .;
  } > RAM
}
