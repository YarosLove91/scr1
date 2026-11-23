/*
 * link.ld — SCR1 fuzz programs (riscv-dv pygen output).
 *
 * The image starts at 0x200 = SCR1 reset vector (SCR1_ARCH_RST_VECTOR) and
 * must fit the 64K RAM window at 0x0 (memory tb / Spike -m0x0:0x10000 /
 * DPI cosim region). No TCM relocation: everything executes from RAM.
 * Stacks are shrunk to STACK_MAX words by dv/fuzz/tools/patch_asm.py.
 */

OUTPUT_ARCH( "riscv" )
ENTRY( _start )

MEMORY
{
  ram (wxa!ri) : ORIGIN = 0x200, LENGTH = 64K - 512
  /* SCR1 tb exit marker cell: the native crt places an endless `j .`
     at 0xF8 so the core spins legally after the epilogue jump; without
     it the core fetches zeros at 0xF8 and falls into an endless
     illegal-instruction trap loop after the run verdict */
  exit_vec (wx) : ORIGIN = 0xF8, LENGTH = 4
}

SECTIONS
{
  .exit_vec :
  {
    *(.exit_vec)
  } > exit_vec

  .text :
  {
    *(.text.init)
    *(.text)
    *(.text.*)
  } > ram

  .rodata :
  {
    . = ALIGN(4);
    *(.rodata)
    *(.rodata.*)
  } > ram

  .data :
  {
    . = ALIGN(4);
    *(.data)
    *(.data.*)
  } > ram

  .bss :
  {
    . = ALIGN(4);
    *(.bss)
    *(.bss.*)
  } > ram

  .user_stack :
  {
    . = ALIGN(4);
    *(.user_stack)
  } > ram

  .kernel_stack :
  {
    . = ALIGN(4);
    *(.kernel_stack)
  } > ram

  .kernel_data :
  {
    . = ALIGN(4);
    *(.kernel_data)
    *(.kernel_data.*)
  } > ram

  _end = .;
}
