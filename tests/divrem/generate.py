#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Demerzel Solutions Limited
# SPDX-License-Identifier: MIT
"""Generate a freestanding RV64 guest with Python integer division as its oracle."""

import random
import sys
from pathlib import Path

MASK = 2**256 - 1
ROOT = Path(sys.argv[1])
ROOT.mkdir(parents=True, exist_ok=True)
code = [".option norelax", ".section .text", ".global _start", "_start:",
        "li sp, 0x200400", "li s5, 0", "li s6, 0"]
data = [".section .data", ".balign 8", "result: .zero 64"]
checks = 0


def buffer(value, limbs):
    name = f"v{len(data)}"
    data.append(name + ": .quad " + ", ".join(hex((value >> (64 * i)) & (2**64 - 1)) for i in range(limbs)))
    return name


def check_pair(n, d, q, r, expected):
    global checks
    for reg, value, size in [("a0", n, 8), ("a1", d, 4), ("a2", q, 4), ("a3", r, 4)]:
        code.append(f"la {reg}, {buffer(value, size)}")
    code.extend(["call zkvm_u512_is_divrem", f"xori a0, a0, {expected}", "call check_bool"])
    checks += 1


def hint(n, d):
    global checks
    q, r = divmod(n, d) if d else (0, 0)
    n_label, d_label = buffer(n, 8), buffer(d, 4)
    code.extend([f"la a0, {n_label}", f"la a1, {d_label}", "la a2, result",
                 "call zkvm_u512_divrem_hint", "la a0, result",
                 f"la a1, {buffer((q & MASK) | (r << 256), 8)}", "call check_words",
                 f"la a0, {n_label}", f"la a1, {d_label}", "la a2, result",
                 "addi a3, a2, 32", "call zkvm_u512_is_divrem",
                 f"xori a0, a0, {int(d != 0 and q <= MASK)}", "call check_bool"])
    checks += 2


rng = random.Random(1)
edges = [0, 1, 2, 2**64 - 1, 2**64, 2**128 - 1, 2**128, 2**255, MASK]
pairs = [(a, b) for a in edges for b in edges]
pairs += [(rng.getrandbits(256), rng.getrandbits(256)) for _ in range(64)]
for a, b in pairs:
    code.extend([f"la a0, {buffer(a, 4)}", f"la a1, {buffer(b, 4)}", "la a2, result",
                 "call zkvm_u256_mul_wide", "la a0, result",
                 f"la a1, {buffer(a * b, 8)}", "call check_words"])
    checks += 1
    hint(a * b, b)

for d in edges[1:] + [rng.randrange(1, MASK) for _ in range(32)]:
    q, r = rng.getrandbits(256), rng.randrange(d)
    n = q * d + r
    hint(n, d)
    check_pair(n, d, q, r, 1)
    check_pair(n, d, q ^ 1, r, 0)
    check_pair(n, d, q, r ^ 1, 0)
    check_pair(n ^ (1 << 511), d, q, r, 0)
    # The equation still holds, but the remainder is not canonical.
    check_pair(d, d, 0, d, 0)
    if 2 * d - 1 <= MASK:
        check_pair(2 * d - 1, d, 0, 2 * d - 1, 0)

for n, d in [(0, 0), (MASK, 0), (2**512 - 1, 1), (2**256, 1),
             (2**512 - 1, MASK), (MASK * MASK + MASK - 1, MASK)]:
    hint(n, d)
check_pair(0, 0, 0, 0, 0)

# REVEAL and TERMINATE use the encodings in OpenVM's RV64 guest crate.
code.extend(["li a0, 0", ".insn i 0x0b, 2, a0, s5, 0", "li a0, 8",
             ".insn i 0x0b, 2, a0, s6, 0", "li a0, 16",
             ".insn i 0x0b, 2, a0, zero, 0", "li a0, 24",
             ".insn i 0x0b, 2, a0, zero, 0", ".insn i 0x0b, 0, zero, zero, 0",
             "check_words:", "li t0, 8", "li t1, 0", "1:",
             "ld t2, 0(a0)", "ld t3, 0(a1)", "xor t2, t2, t3", "or t1, t1, t2",
             "addi a0, a0, 8", "addi a1, a1, 8", "addi t0, t0, -1", "bnez t0, 1b",
             "mv a0, t1", "check_bool:", "snez a0, a0", "add s5, s5, a0",
             "addi s6, s6, 1", "ret"])
ROOT.joinpath("guest.S").write_text("\n".join(code + data) + "\n")
ROOT.joinpath("expected.txt").write_text("public_values=" + (bytes(8) + checks.to_bytes(8, "little") + bytes(16)).hex() + "\n")
ROOT.joinpath("empty.raw").write_bytes(b"")
print(f"Generated {checks} checks")
