/**
 * @file
 * @brief OpenVM intrinsics (custom-instruction based)
 *
 * OpenVM has no syscalls at all: every accelerated primitive is a custom
 * instruction under RISC-V custom-0 (opcode 0x0b), distinguished by funct3 and
 * funct7. Encodings are taken from the guest crates on the RV64 branch
 * (openvm, branch develop-v2.1.0-rv64):
 *
 *   extensions/keccak256/guest/src/lib.rs   funct3 0b100, funct7 0 (keccakf), 1 (xorin)
 *   extensions/sha2/guest/src/lib.rs        funct3 0b100, funct7 2 (sha256), 3 (sha512)
 *   extensions/bigint/guest/src/lib.rs      funct3 0b101, funct7 = Int256Funct7
 *
 * ALIGNMENT IS THE CALLER'S JOB. OpenVM's own Rust wrappers spend most of
 * their body bouncing unaligned buffers through a temporary; these shims do
 * not, so every pointer passed here MUST be 8-byte aligned. That is free for
 * us - the guest heap hands out 8-aligned blocks - and it keeps each
 * primitive at exactly one instruction.
 *
 * Copyright (C) 2026 Demerzel Solutions Limited (Nethermind)
 *
 * @author Maxim Menshikov <maksim.menshikov@nethermind.io>
 */
.option norelax

/* R-type custom instruction over three pointer arguments:
 *   rd = a0, rs1 = a1, rs2 = a2 - matching the (result, a, b) order the
 *   OpenVM externs use. */
.macro OPENVM_R3 name, funct3, funct7
    .section .text, "ax", @progbits
    .balign 4
    .global \name
    .type \name, @function
\name:
    .cfi_startproc
    /* leaf: no stack frame */
    .insn   r 0x0b, \funct3, \funct7, a0, a1, a2
    ret
    .cfi_endproc
    .size \name, .-\name
.endm

/* R-type over a single in/out buffer: rd = a0, rs1 = rs2 = x0. */
.macro OPENVM_R1 name, funct3, funct7
    .section .text, "ax", @progbits
    .balign 4
    .global \name
    .type \name, @function
\name:
    .cfi_startproc
    /* leaf: no stack frame */
    .insn   r 0x0b, \funct3, \funct7, a0, x0, x0
    ret
    .cfi_endproc
    .size \name, .-\name
.endm

/* ---- Keccak-f[1600] ----------------------------------------------------
 * keccakf(buffer): permutes 200 bytes in place.
 * xorin(buffer, input, len): absorbs len bytes; len <= 136 (KECCAK_RATE) -
 * a larger value executes but fails to prove, so the managed side must
 * chunk. */
OPENVM_R1  zkvm_keccakf,                0b100, 0
OPENVM_R3  zkvm_keccak_xorin,           0b100, 1

/* ---- SHA-2 compression -------------------------------------------------
 * zkvm_sha256_impl(state, input, output) - note the register order: the
 * instruction takes rd = output, rs1 = state, rs2 = input, so the shim
 * shuffles the C arguments into place rather than using OPENVM_R3. */
    .section .text, "ax", @progbits
    .balign 4
    .global zkvm_sha256_compress
    .type zkvm_sha256_compress, @function
zkvm_sha256_compress:
    .cfi_startproc
    .insn   r 0x0b, 0b100, 2, a2, a0, a1
    ret
    .cfi_endproc
    .size zkvm_sha256_compress, .-zkvm_sha256_compress

    .section .text, "ax", @progbits
    .balign 4
    .global zkvm_sha512_compress
    .type zkvm_sha512_compress, @function
zkvm_sha512_compress:
    .cfi_startproc
    .insn   r 0x0b, 0b100, 3, a2, a0, a1
    ret
    .cfi_endproc
    .size zkvm_sha512_compress, .-zkvm_sha512_compress

/* ---- 256-bit integer arithmetic ----------------------------------------
 * All take (result, a, b) over 32-byte little-endian operands. funct7 is the
 * Int256Funct7 discriminant. */
OPENVM_R3  zkvm_u256_add,               0b101, 0
OPENVM_R3  zkvm_u256_sub,               0b101, 1
OPENVM_R3  zkvm_u256_xor,               0b101, 2
OPENVM_R3  zkvm_u256_or,                0b101, 3
OPENVM_R3  zkvm_u256_and,               0b101, 4
OPENVM_R3  zkvm_u256_sll,               0b101, 5
OPENVM_R3  zkvm_u256_srl,               0b101, 6
OPENVM_R3  zkvm_u256_sra,               0b101, 7
OPENVM_R3  zkvm_u256_slt,               0b101, 8
OPENVM_R3  zkvm_u256_sltu,              0b101, 9
OPENVM_R3  zkvm_u256_mul,               0b101, 10

/* ---- 512-by-256-bit division hint --------------------------------------
 * Not instructions of OpenVM's extensions: a phantom only runner/ registers,
 * and two plain RV64IM routines that check its answer. Together they give a
 * guest (a * b) mod m without dividing in software. */

/* void zkvm_u512_divrem_hint(const uint64_t numerator[8],
 *                            const uint64_t divisor[4],
 *                            uint64_t quotient_remainder[8])
 *
 * Asks the runner for numerator / divisor and numerator mod divisor, the
 * quotient truncated to 256 bits, and stores them little-endian, quotient
 * first. The phantom (custom-0, funct3 0b011, imm 0x4d1) is not part of
 * OpenVM's SDK configuration: any other runner transpiles it to unimp and
 * traps. HINT_BUFFER (funct3 0b001, imm 1) then copies the 8 hinted
 * doublewords. Nothing here is checked: the caller verifies the pair with
 * zkvm_u512_is_divrem. */
    .section .text, "ax", @progbits
    .balign 4
    .global zkvm_u512_divrem_hint
    .type zkvm_u512_divrem_hint, @function
zkvm_u512_divrem_hint:
    .cfi_startproc
    .insn   i 0x0b, 0b011, a0, a1, 0x4d1
    li      t0, 8
    .insn   i 0x0b, 0b001, a2, t0, 1
    ret
    .cfi_endproc
    .size zkvm_u512_divrem_hint, .-zkvm_u512_divrem_hint

/* The 512-bit product of the limbs at a0 and the four limbs preloaded in
 * t0..t3, plus the four preloaded in a4..a7. Schoolbook on MULHU, which
 * managed code cannot reach on this target (Math.BigMul there is four 32-bit
 * products). Leaves the eight result limbs in a4 a5 a6 a7 t4 t5 t6 a1, least
 * significant first; a2 and s0..s3 are scratch. */
.macro MAC_FIRST col, yj
    mul     s0, a2, \yj
    mulhu   s1, a2, \yj
    add     \col, \col, s0
    sltu    s3, \col, s0
    add     s2, s1, s3
.endm

.macro MAC col, yj
    mul     s0, a2, \yj
    mulhu   s1, a2, \yj
    add     s0, s0, s2
    sltu    s3, s0, s2
    add     s1, s1, s3
    add     \col, \col, s0
    sltu    s3, \col, s0
    add     s2, s1, s3
.endm

.macro ROW off, c0, c1, c2, c3, c4
    ld      a2, \off(a0)
    MAC_FIRST \c0, t0
    MAC     \c1, t1
    MAC     \c2, t2
    MAC     \c3, t3
    mv      \c4, s2
.endm

.macro MUL_ADD_512
    ROW     0, a4, a5, a6, a7, t4
    ROW     8, a5, a6, a7, t4, t5
    ROW     16, a6, a7, t4, t5, t6
    ROW     24, a7, t4, t5, t6, a1
.endm

.macro SAVE_S0_S4
    addi    sp, sp, -48
    .cfi_def_cfa_offset 48
    sd      s0, 0(sp)
    sd      s1, 8(sp)
    sd      s2, 16(sp)
    sd      s3, 24(sp)
    sd      s4, 32(sp)
.endm

.macro RESTORE_S0_S4
    ld      s0, 0(sp)
    ld      s1, 8(sp)
    ld      s2, 16(sp)
    ld      s3, 24(sp)
    ld      s4, 32(sp)
    addi    sp, sp, 48
    .cfi_def_cfa_offset 0
.endm

/* void zkvm_u256_mul_wide(const uint64_t x[4], const uint64_t y[4],
 *                         uint64_t product[8]) */
    .section .text, "ax", @progbits
    .balign 4
    .global zkvm_u256_mul_wide
    .type zkvm_u256_mul_wide, @function
zkvm_u256_mul_wide:
    .cfi_startproc
    SAVE_S0_S4
    mv      s4, a2
    ld      t0, 0(a1)
    ld      t1, 8(a1)
    ld      t2, 16(a1)
    ld      t3, 24(a1)
    li      a4, 0
    li      a5, 0
    li      a6, 0
    li      a7, 0
    MUL_ADD_512
    sd      a4, 0(s4)
    sd      a5, 8(s4)
    sd      a6, 16(s4)
    sd      a7, 24(s4)
    sd      t4, 32(s4)
    sd      t5, 40(s4)
    sd      t6, 48(s4)
    sd      a1, 56(s4)
    RESTORE_S0_S4
    ret
    .cfi_endproc
    .size zkvm_u256_mul_wide, .-zkvm_u256_mul_wide

/* int zkvm_u512_is_divrem(const uint64_t numerator[8],
 *                         const uint64_t divisor[4],
 *                         const uint64_t quotient[4],
 *                         const uint64_t remainder[4])
 *
 * 1 when quotient * divisor + remainder is exactly the 512-bit numerator and
 * remainder < divisor, which pins both to the true quotient and remainder
 * whatever the hint said; 0 otherwise. */
    .section .text, "ax", @progbits
    .balign 4
    .global zkvm_u512_is_divrem
    .type zkvm_u512_is_divrem, @function
zkvm_u512_is_divrem:
    .cfi_startproc
    SAVE_S0_S4
    mv      s4, a0
    ld      t0, 0(a1)
    ld      t1, 8(a1)
    ld      t2, 16(a1)
    ld      t3, 24(a1)
    ld      a4, 0(a3)
    ld      a5, 8(a3)
    ld      a6, 16(a3)
    ld      a7, 24(a3)
    /* remainder < divisor, from the top limb down */
    bltu    a7, t3, 1f
    bne     a7, t3, 2f
    bltu    a6, t2, 1f
    bne     a6, t2, 2f
    bltu    a5, t1, 1f
    bne     a5, t1, 2f
    bgeu    a4, t0, 2f
1:
    mv      a0, a2
    MUL_ADD_512
    ld      s0, 0(s4)
    xor     s0, s0, a4
    ld      s1, 8(s4)
    xor     s1, s1, a5
    or      s0, s0, s1
    ld      s1, 16(s4)
    xor     s1, s1, a6
    or      s0, s0, s1
    ld      s1, 24(s4)
    xor     s1, s1, a7
    or      s0, s0, s1
    ld      s1, 32(s4)
    xor     s1, s1, t4
    or      s0, s0, s1
    ld      s1, 40(s4)
    xor     s1, s1, t5
    or      s0, s0, s1
    ld      s1, 48(s4)
    xor     s1, s1, t6
    or      s0, s0, s1
    ld      s1, 56(s4)
    xor     s1, s1, a1
    or      s0, s0, s1
    seqz    a0, s0
    .cfi_remember_state
    RESTORE_S0_S4
    ret
2:
    .cfi_restore_state
    li      a0, 0
    RESTORE_S0_S4
    ret
    .cfi_endproc
    .size zkvm_u512_is_divrem, .-zkvm_u512_is_divrem
