/* C906L entry: M-mode, physical addresses, started at C906L_BASE by
 * nanokvm-kvm through the reset-vector registers. */
	.section .text.start, "ax"
	.globl _start
_start:
	csrw	mie, zero
	/* Invalidate I/D caches, BHT and BTB, then enable the caches, branch
	 * prediction and write-allocate (mcor 0x7c2, mhcr 0x7c1), and the data
	 * prefetcher (mhint 0x7c5), as the vendor RTOS does. */
	li	t0, 0x30013
	csrs	0x7c2, t0
	li	t0, 0x7f
	csrs	0x7c1, t0
	li	t0, 0x610c
	csrs	0x7c5, t0
	/* Floating point on (libjpeg's float paths are unused, but compilers
	 * may still emit FP moves). */
	li	t0, 1 << 13
	csrs	mstatus, t0
	la	sp, __stack_top
	la	t0, __bss_start
	la	t1, __bss_end
1:	bgeu	t0, t1, 2f
	sd	zero, 0(t0)
	addi	t0, t0, 8
	j	1b
2:	call	main
3:	wfi
	j	3b
