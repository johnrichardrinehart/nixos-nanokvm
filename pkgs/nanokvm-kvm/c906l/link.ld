/* The firmware's 1 MiB at the start of the C906L region (protocol.h). */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
	FW (rwx) : ORIGIN = 0x8f800000, LENGTH = 1M
}

SECTIONS
{
	.text : {
		KEEP(*(.text.start))
		*(.text .text.*)
	} > FW
	.rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > FW
	.data : { *(.data .data.* .sdata .sdata.*) } > FW
	.bss (NOLOAD) : ALIGN(64) {
		__bss_start = .;
		*(.bss .bss.* .sbss .sbss.* COMMON)
		. = ALIGN(64);
		__bss_end = .;
	} > FW
	/* The heap runs from here up to the stack. */
	__heap_start = ALIGN(64);
	__stack_top = ORIGIN(FW) + LENGTH(FW);
	/DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.riscv.attributes) }
}
