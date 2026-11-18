/**
 * @file
 * @brief ZKVM OpenVM implementation.
 *
 * OpenVM's RV64 line (openvm-org/openvm, branch develop-v2.1.0-rv64) proves
 * RV64IM with lp64 and no A/C extension. The transpiler
 * (crates/toolchain/transpiler/src/elf.rs) reads PT_LOAD program headers,
 * requires a 64-bit ELF, and does NOT set up sp - _start points it at the
 * stack itself, as OpenVM's own Rust entrypoint does
 * (crates/toolchain/openvm/src/lib.rs).
 *
 * Copyright (C) 2026 Demerzel Solutions Limited (Nethermind)
 *
 * @author Maxim Menshikov <maksim.menshikov@nethermind.io>
 */
.option norelax

.section .rodata
    .balign 8
app_str:
    .asciz "app"

    .section .data
    .balign 8
argv_vec:
    .dword app_str
    .dword 0

/* See the note in bflat-sp1's platform/entry.S: the managed binding is named
 * syscall_keccak_f after ziskos, OpenVM spells it zkvm_keccakf, and the
 * standard defines no permutation to agree on. Same section trick, so a guest
 * built without --extlib does not acquire a reference to the bindings
 * library. */
.section .text.syscall_keccak_f,"ax",@progbits
.global syscall_keccak_f
.type   syscall_keccak_f, @function
syscall_keccak_f:
    .cfi_startproc
    tail    zkvm_keccakf
    .cfi_endproc
    .size   syscall_keccak_f, .-syscall_keccak_f


/* ------------------------------------------------------------------------
 * The platform interface of bflat's modules (docs/manifest.md in
 * bflat-riscv64, "Platform interface"): OpenVM's custom-0 instructions. They
 * stay out of bflat's shared objects, so that no other platform's image
 * carries an encoding it cannot decode (SP1 transpiles every word of .text up
 * front and rejects custom opcodes). OpenVM defines no
 * zkvm_platform_syscall: it has no ecall handler at all, so pal's syscall
 * fails instead.
 * ------------------------------------------------------------------------ */

/* zkvm_platform_exit(long code): TERMINATE (custom-0, funct3 0). The exit
 * code is an immediate, so a runtime code collapses to OpenVM's two
 * outcomes: 0 success, 1 failure (openvm::process::exit / panic). */
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

/* zkvm_platform_write(int fd, const char *buf, int len): the PrintStr
 * phantom - custom-0, funct3 3, imm 1, buffer in rd, length in rs1
 * (openvm/extensions/riscv/guest/src/io.rs raw_print_str_from_bytes). It has
 * a single output channel, so fd is ignored. */
.section .text.zkvm_platform_write,"ax",@progbits
.global zkvm_platform_write
.type   zkvm_platform_write, @function
zkvm_platform_write:
    .cfi_startproc
    .insn   i 0x0b, 3, a1, a2, 1  # rd = buf (a1), rs1 = len (a2)
    ret
    .cfi_endproc
    .size   zkvm_platform_write, .-zkvm_platform_write

.section .text.init
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

    /* noos_start_main replaces musl's __libc_start_main: it initialises the
     * thread pointer, runs .init_array and calls uBootstrap_main. musl's
     * startup exists to parse auxv and set up an environment this guest does
     * not have, and it costs 126 instructions the VM cannot decode. */
    li      a0, 1            # argc = 1
    la      a1, argv_vec     # argv = &argv_vec[0]
    call    noos_start_main
    # Unreachable: noos_start_main exits through musl's exit(), which pal
    # turns into zkvm_platform_exit, the TERMINATE above. Kept as a
    # backstop - TERMINATE with exit code 0 (custom-0 opcode 0x0b, funct3 0,
    # rd = rs1 = x0, imm = exit code; see openvm_platform::rust_rt).
    .insn   i 0x0b, 0, x0, x0, 0
1:  j       1b               # loop forever
    .cfi_endproc

/* void *__wrap_memcpy(void *dst, const void *src, size_t n), reached through
 * --wrap=memcpy (declared in openvm.bflat.manifest).
 *
 * musl's generic C memcpy moves 32-bit words and merges a misaligned source
 * with 32-bit shifts. OpenVM's rv64 loads and stores take any address at the
 * cost of an aligned one (an access that straddles two 8-byte blocks is still
 * one row), so this moves 64-bit words without aligning either side, and
 * finishes with the copy's last word rather than a byte loop. SP1's version
 * (bflat-sp1's platform/entry.S) aligns instead, because SP1 rejects misaligned access.
 *
 * Weak so a guest that still links its own __wrap_memcpy keeps it rather than
 * failing the link on a duplicate definition. */
.section .text.__wrap_memcpy,"ax",@progbits
.weak   __wrap_memcpy
.type   __wrap_memcpy, @function
.p2align 2
__wrap_memcpy:
    .cfi_startproc
    mv      t6, a0
    li      t0, 8
    bltu    a2, t0, .Lbytes

    /* The last word, read before the loop and stored after it: it may
     * overlap the loop's last word, which it rewrites with the same bytes. */
    add     a3, a1, a2
    add     a4, a0, a2
    ld      t5, -8(a3)
    li      t1, 32
    bltu    a2, t1, .Lwords
    /* 64 bytes per iteration while they last, since the loop's count, pointer
     * and branch instructions cost as much as its loads and stores. */
    li      a6, 64
    bltu    a2, a6, .Lblocks
.Lblocks64:
    ld      t2, 0(a1)
    ld      t3, 8(a1)
    ld      t4, 16(a1)
    ld      a5, 24(a1)
    sd      t2, 0(t6)
    sd      t3, 8(t6)
    sd      t4, 16(t6)
    sd      a5, 24(t6)
    ld      t2, 32(a1)
    ld      t3, 40(a1)
    ld      t4, 48(a1)
    ld      a5, 56(a1)
    sd      t2, 32(t6)
    sd      t3, 40(t6)
    sd      t4, 48(t6)
    sd      a5, 56(t6)
    addi    a1, a1, 64
    addi    t6, t6, 64
    addi    a2, a2, -64
    bgeu    a2, a6, .Lblocks64
    bltu    a2, t1, .Lwords
.Lblocks:
    ld      t2, 0(a1)
    ld      t3, 8(a1)
    ld      t4, 16(a1)
    ld      a5, 24(a1)
    sd      t2, 0(t6)
    sd      t3, 8(t6)
    sd      t4, 16(t6)
    sd      a5, 24(t6)
    addi    a1, a1, 32
    addi    t6, t6, 32
    addi    a2, a2, -32
    bgeu    a2, t1, .Lblocks
.Lwords:
    bltu    a2, t0, .Ltail
.Lword:
    ld      t2, 0(a1)
    sd      t2, 0(t6)
    addi    a1, a1, 8
    addi    t6, t6, 8
    addi    a2, a2, -8
    bgeu    a2, t0, .Lword
.Ltail:
    sd      t5, -8(a4)
    ret

.Lbytes:
    beqz    a2, .Ldone
.Lbyte:
    lbu     t1, 0(a1)
    sb      t1, 0(t6)
    addi    a1, a1, 1
    addi    t6, t6, 1
    addi    a2, a2, -1
    bnez    a2, .Lbyte
.Ldone:
    ret
    .cfi_endproc
    .size   __wrap_memcpy, .-__wrap_memcpy

/* void *__wrap_memmove(void *dst, const void *src, size_t n), reached through
 * --wrap=memmove (declared in openvm.bflat.manifest).
 *
 * musl's memmove checks for overlap and tail-calls memcpy for almost every
 * call. A destination below the source, or past its end, is copied forward by
 * __wrap_memcpy, which reads every source word, its last word included,
 * before storing over it. Only a destination inside the source is copied
 * backward, mirroring __wrap_memcpy: unaligned 64-bit words, finishing with
 * the copy's first word, read before the loop.
 *
 * Weak for the same reason as __wrap_memcpy. */
.section .text.__wrap_memmove,"ax",@progbits
.weak   __wrap_memmove
.type   __wrap_memmove, @function
.p2align 2
__wrap_memmove:
    .cfi_startproc
    sub     t0, a0, a1
    bltu    t0, a2, .Lmove_backward
    tail    __wrap_memcpy

    /* dst - src < n, so n > 0. t6 and a1 walk down from the ends of the
     * destination and source. */
.Lmove_backward:
    add     t6, a0, a2
    add     a1, a1, a2
    li      t0, 8
    bltu    a2, t0, .Lmove_byte

    /* The first word, read before the loop and stored after it: it may
     * overlap the loop's last word, which it rewrites with the same bytes. */
    sub     a3, a1, a2
    ld      t5, 0(a3)
    li      t1, 32
    bltu    a2, t1, .Lmove_words
.Lmove_blocks:
    ld      t2, -8(a1)
    ld      t3, -16(a1)
    ld      t4, -24(a1)
    ld      a5, -32(a1)
    sd      t2, -8(t6)
    sd      t3, -16(t6)
    sd      t4, -24(t6)
    sd      a5, -32(t6)
    addi    a1, a1, -32
    addi    t6, t6, -32
    addi    a2, a2, -32
    bgeu    a2, t1, .Lmove_blocks
.Lmove_words:
    bltu    a2, t0, .Lmove_head
.Lmove_word:
    ld      t2, -8(a1)
    sd      t2, -8(t6)
    addi    a1, a1, -8
    addi    t6, t6, -8
    addi    a2, a2, -8
    bgeu    a2, t0, .Lmove_word
.Lmove_head:
    sd      t5, 0(a0)
    ret

.Lmove_byte:
    addi    a1, a1, -1
    addi    t6, t6, -1
    lbu     t1, 0(a1)
    sb      t1, 0(t6)
    addi    a2, a2, -1
    bnez    a2, .Lmove_byte
    ret
    .cfi_endproc
    .size   __wrap_memmove, .-__wrap_memmove

/* void *__wrap_memset(void *dst, int c, size_t n), reached through
 * --wrap=memset (declared in openvm.bflat.manifest).
 *
 * musl's memset stores 32-bit words before its 64-bit loop. Like
 * __wrap_memcpy, this stores unaligned 64-bit words, 32 bytes per iteration,
 * and finishes with the fill's last word rather than a byte loop.
 *
 * Weak for the same reason as __wrap_memcpy. */
.section .text.__wrap_memset,"ax",@progbits
.weak   __wrap_memset
.type   __wrap_memset, @function
.p2align 2
__wrap_memset:
    .cfi_startproc
    mv      t6, a0
    andi    a1, a1, 0xff
    li      t0, 8
    bltu    a2, t0, .Lset_bytes

    /* Most fills are zero, which needs no broadcast. */
    beqz    a1, .Lset_broadcast_done
    slli    t1, a1, 8
    or      a1, a1, t1
    slli    t1, a1, 16
    or      a1, a1, t1
    slli    t1, a1, 32
    or      a1, a1, t1
.Lset_broadcast_done:
    /* The last word may overlap the loop's last word, which it rewrites with
     * the same bytes. */
    add     a4, a0, a2
    sd      a1, -8(a4)
    li      t1, 32
    bltu    a2, t1, .Lset_words
.Lset_blocks:
    sd      a1, 0(t6)
    sd      a1, 8(t6)
    sd      a1, 16(t6)
    sd      a1, 24(t6)
    addi    t6, t6, 32
    addi    a2, a2, -32
    bgeu    a2, t1, .Lset_blocks
.Lset_words:
    bltu    a2, t0, .Lset_done
.Lset_word:
    sd      a1, 0(t6)
    addi    t6, t6, 8
    addi    a2, a2, -8
    bgeu    a2, t0, .Lset_word
.Lset_done:
    ret

.Lset_bytes:
    beqz    a2, .Lset_done
.Lset_byte:
    sb      a1, 0(t6)
    addi    t6, t6, 1
    addi    a2, a2, -1
    bnez    a2, .Lset_byte
    ret
    .cfi_endproc
    .size   __wrap_memset, .-__wrap_memset
