/**
 * @file
 * @brief ZKVM OpenVM RV32 entry (OpenVM main line, RV32IM, ilp32).
 *
 * Same custom-0 platform interface as the RV64 entry.S; OpenVM's RV32 memory
 * is word-granular (word accesses must be 4-aligned), so musl's own aligned
 * memcpy/memmove/memset are kept and no wrappers are provided here.
 */
    .option norvc
    .option norelax

.section .rodata
    .balign 4
app_str:
    .asciz "app"

    .section .data
    .balign 4
argv_vec:
    .word app_str
    .word 0

.section .text.syscall_keccak_f,"ax",@progbits
.global syscall_keccak_f
.type   syscall_keccak_f, @function
syscall_keccak_f:
    .cfi_startproc
    tail    zkvm_keccakf
    .cfi_endproc
    .size   syscall_keccak_f, .-syscall_keccak_f

/* zkvm_platform_exit(int code): TERMINATE (custom-0, funct3 0), 0 success, 1 failure. */
.section .text.zkvm_platform_exit,"ax",@progbits
.global zkvm_platform_exit
.type   zkvm_platform_exit, @function
zkvm_platform_exit:
    .cfi_startproc
    beqz    a0, 1f
    .insn   i 0x0b, 0, x0, x0, 1
2:  j       2b
1:  .insn   i 0x0b, 0, x0, x0, 0
3:  j       3b
    .cfi_endproc
    .size   zkvm_platform_exit, .-zkvm_platform_exit

/* zkvm_platform_write(int fd, const char *buf, int len): PrintStr phantom. */
.section .text.zkvm_platform_write,"ax",@progbits
.global zkvm_platform_write
.type   zkvm_platform_write, @function
zkvm_platform_write:
    .cfi_startproc
    .insn   i 0x0b, 3, a1, a2, 1
    ret
    .cfi_endproc
    .size   zkvm_platform_write, .-zkvm_platform_write

.section .text.init, "ax", @progbits
.global _start
    .cfi_sections .eh_frame
_start:
    .cfi_startproc
    .cfi_def_cfa sp, 0
    .cfi_undefined ra
    .option push
    .option norelax
    la      gp, _global_pointer
    .option pop
    la      sp, _init_stack_top
    li      a0, 1
    la      a1, argv_vec
    call    noos_start_main
    .insn   i 0x0b, 0, x0, x0, 0
1:  j       1b
    .cfi_endproc
    .size   _start, .-_start
