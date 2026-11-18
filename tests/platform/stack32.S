/* Different BSS sizes must not change the ABI alignment of the initial stack. */
.section .text.init,"ax",@progbits
.global _start
_start:
    la sp, _init_stack_top
    .insn i 0x0b, 0, x0, x0, 0

.section .bss
.balign 8
.space BSS_SIZE
