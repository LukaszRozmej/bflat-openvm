# bflat-openvm

[![Nethermind.OpenVM.Runtime](https://img.shields.io/nuget/v/Nethermind.OpenVM.Runtime)](https://www.nuget.org/packages/Nethermind.OpenVM.Runtime)

OpenVM bindings for [bflat-riscv64](https://github.com/NethermindEth/bflat-riscv64)
guests built with `--libc openvm`, providing the native half of
[Nethermind.Zkvm.Abstractions](https://www.nuget.org/packages/Nethermind.Zkvm.Abstractions).

## What this is

`libopenvm.a` — the native half of the eth-act zkVM standards for an OpenVM
guest, in three layers:

1. **`openvm-accelerators`**, OpenVM's own implementation of the
   [C interface for cryptographic accelerators](https://github.com/eth-act/zkvm-standards/tree/main/standards/c-interface-accelerators),
   from [axiom-crypto/openvm-eth](https://github.com/axiom-crypto/openvm-eth).
   All 19 entry points, host-tested upstream, and the same code ere-guests'
   OpenVM guest is built on. We reimplement none of it.
2. **`src/accel-rs`**, the staticlib wrapper, which supplies the three things
   that crate leaves to the program: the curve and modulus registration
   (`src/init.rs`), the
   [IO interface](https://github.com/eth-act/zkvm-standards/tree/main/standards/io-interface)
   (`src/io.rs`), and the `__sync_*` builtins an rv64im target needs and no
   toolchain provides (`src/sync.rs`).
3. **`src/openvm_intrinsics`**, one instruction per accelerated primitive, for
   code that wants a permutation or a 256-bit ALU op directly rather than
   through the standard. OpenVM has no syscalls: each primitive is a custom
   instruction under RISC-V custom-0 (`0x0b`) or custom-1 (`0x2b`).

Dependencies are pinned to `develop-v2.1.0`, OpenVM's live RV64 line — not
`develop-v2.1.0-rv64` (an older snapshot of the same work) and not `main`,
which is still RV32 and rejects a 64-bit ELF outright.

## Usage

```console
$ bflat build app.cs --os linux --arch riscv64 --libc openvm \
      --extlib path/to/libopenvm.bflat.manifest
```

## Building

```console
$ ./build/build.sh
```

Needs `binutils-riscv64-linux-gnu` and a nightly Rust toolchain with
`rust-src`: the accelerators are built for a custom bare-metal target that
ships no prebuilt `core`, so `-Z build-std` is required. The cross-tool names
are all overridable (`AS`, `AR`, `RANLIB`, `OBJCOPY`, `OBJDUMP`, `NM`) for
hosts that spell them differently.

## Coverage

All 19 accelerators, plus both IO entry points:

| Entry points | Implementation |
|---|---|
| `zkvm_keccak256`, `zkvm_sha256` | OpenVM's keccak and sha2 extensions |
| `zkvm_secp256k1_verify`, `zkvm_secp256r1_verify` | the accelerated `k256` / `p256` |
| `zkvm_secp256k1_ecrecover` | `src/accel-rs/src/ecrecover.rs`: GLV and wNAF on the ecc and algebra extensions |
| `zkvm_bn254_g1_add`, `zkvm_bn254_g1_mul`, `zkvm_bn254_pairing` | the pairing extension |
| `zkvm_bls12_g1_add`, `g1_msm`, `g2_add`, `g2_msm`, `pairing`, `map_fp_to_g1`, `map_fp2_to_g2` | the pairing extension |
| `zkvm_kzg_point_eval` | `openvm-kzg` |
| `zkvm_modexp` | accelerated for a BN254-Fr modulus, `aurora-engine-modexp` otherwise |
| `zkvm_ripemd160`, `zkvm_blake2f` | software — OpenVM has no extension for either, on any branch |
| `read_input`, `write_output` | `src/io.rs` |

`build/build.sh` fails if any of those is missing from the archive, and counts
custom-0 and custom-1 instructions to catch a silent fallback to portable Rust.
CI then links a real bflat guest that calls all 21 through direct P/Invoke
(`tests/integration/guest.cs`) — which is what proves the symbols not only
exist but survive a guest's link. The 256-bit integer shims are also executed:
`tests/integration/u256.cs` runs each against precomputed vectors on the
OpenVM runner, out of place and over either operand.

`zkvm_secp256k1_ecrecover` is ours rather than openvm-eth's, so it is also
tested for results: `tests/secp256k1/test_ecrecover.py` diffs a host build of
it against a Python reference over known, random, malformed and adversarial
vectors, failing on any curve operation the OpenVM chips would not prove, and
CI runs the same vectors through `tests/secp256k1/guest.cs` on the OpenVM
runner.

## The output window is 32 bytes

`write_output` appends, and multiple calls concatenate, as the standard
requires — but only up to 32 bytes, past which it panics rather than drop
bytes. That is a property of the target, not a policy choice: OpenVM's public
output is a byte-addressed buffer written a `u64` at a time, and only the first
32 bytes are guaranteed to exist. ere-guests' OpenVM platform takes the same
limit and asserts on anything longer. A guest with more to publish should
publish a hash of it, which is what OpenVM recommends regardless.

## Why the curves need an explicit init

OpenVM's algebra, ecc and pairing extensions split each accelerated operation
in two: the library declares it as an `extern "C"` symbol, and the *program*
defines it by naming the concrete moduli, complex extensions and curves it uses
— what `cargo openvm` generates as `openvm_init.rs` for a Rust guest. Our guest
is C#, and this staticlib is the only Rust in the link, so that declaration
lives in `src/accel-rs/src/init.rs`. It is the same list, in the same order, as
ere-guests generates for its OpenVM Ethereum guest; the order is part of the
ABI, because `complex_init!` addresses its base field by index into it.

Without it everything still compiles, but every `sw_add_ne_extern_func_*` and
`moduli_setup_extern_func_*` stays undefined and not one custom-1 instruction
is emitted — the curve work would quietly fall back to portable Rust.

## Everything outside the interface is localized

The archive would otherwise export far more than it means to. The accelerated
curves drag in OpenVM's guest runtime (`_start`, `mem*`, `sys_alloc_aligned`),
and `-Z build-std` compiles `compiler_builtins` for a target with no libm, so
it exports the entire C math surface as well. Every one of those collides with
the guest: musl owns the math surface and `mem*`,
`modules/zkvm_openvm/module.S` owns `_start`, and bflat's `rust_sys` module
wraps `sys_alloc_aligned` so OpenVM's bump allocator draws from pal's heap
instead of opening a second one.

So `build/build.sh` localizes everything outside an explicit allowlist. A
duplicate-symbol error is the good outcome here; the bad one is this archive
silently winning over the math surface bflat's `nofp` module is meant to
divert.

## Atomics

OpenVM decodes RV64IM, so there is no `lr`/`sc`/`amo*` for LLVM to lower an
atomic to. The target spec carries `+forced-atomics`, which turns atomic loads
and stores into plain ones plus a `fence` (OpenVM's decoder accepts `fence`; it
rejects `fence.i`), and everything it cannot inline becomes a `__sync_*` call.
`compiler_builtins` implements those only for ARM Thumb, so `src/sync.rs`
provides them: deliberately non-atomic, because an OpenVM guest is single-hart
with no interrupts and no way to create a thread, which makes a plain
load-compare-store indistinguishable from the atomic sequence. CI asserts the
linked image contains no A-extension instruction.

## Constraints

**Every pointer passed to the raw intrinsics must be 8-byte aligned.** OpenVM's
own Rust wrappers spend most of their body bouncing unaligned buffers through a
temporary; these shims do not, which is what keeps each primitive at one
instruction. The standard's entry points stage caller buffers through aligned
locals, so this applies only to `src/openvm_intrinsics` used directly.

**`zkvm_keccak_xorin` absorbs at most 136 bytes** (`KECCAK_RATE`); a larger
length executes but fails to prove. `zkvm_keccak256` chunks for you.

**`zkvm_u512_divrem_hint` runs only on a runner that registers its phantom**
(`runner/`); on any other the instruction transpiles to `unimp` and traps. Its
quotient and remainder are unchecked: accept them only after
`zkvm_u512_is_divrem` returns 1. That check and `zkvm_u256_mul_wide` are plain
RV64IM routines, not extension instructions.

CI builds the runner from this repository and runs `tests/divrem/run.sh` against
it. The generated RV64 guest links the assembly above and checks wide products,
hint round trips, and rejection of invalid pairs against Python integer results.
To run locally, build an image with `docker build -t openvm-divrem-test runner`,
then run `bash tests/divrem/run.sh openvm-divrem-test` (Python 3 and RISC-V
binutils required).
