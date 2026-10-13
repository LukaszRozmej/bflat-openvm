#!/bin/bash
# Builds libopenvm.a - the native half of the OpenVM bindings for bflat guests.
#
# Two layers end up in one archive:
#
#   1. src/accel-rs  - a Rust staticlib implementing the eth-act zkVM
#      accelerator C ABI on top of OpenVM's accelerated guest libraries.
#   2. src/openvm_intrinsics - one instruction per accelerated primitive, for
#      anything the standard does not cover or that managed code wants to reach
#      directly.
#
# WHY A CUSTOM TARGET. OpenVM gates every accelerated path behind
# cfg(any(openvm_intrinsics, target_os = "openvm")). Built for a plain
# riscv64 target the crate still compiles and links, but each primitive
# silently falls back to portable Rust. riscv64im-openvm-elf.json sets
# os = "openvm", which flips those cfgs without needing OpenVM's forked
# toolchain. build.sh checks afterwards that the accelerated instructions are
# actually in the archive, so a silent fallback fails the build.
set -e

fail() { echo "$@" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${ROOT_DIR}/output"
ACCEL_DIR="${ROOT_DIR}/src/accel-rs"
TARGET_JSON="${ACCEL_DIR}/riscv64im-openvm-elf.json"
TARGET_NAME="riscv64im-openvm-elf"

AS="${AS:-riscv64-linux-gnu-as}"
AR="${AR:-riscv64-linux-gnu-ar}"
RANLIB="${RANLIB:-riscv64-linux-gnu-ranlib}"
OBJCOPY="${OBJCOPY:-riscv64-linux-gnu-objcopy}"
OBJDUMP="${OBJDUMP:-riscv64-linux-gnu-objdump}"
NM="${NM:-riscv64-linux-gnu-nm}"
CARGO="${CARGO:-cargo}"
# build-std needs nightly plus the rust-src component.
TOOLCHAIN="${TOOLCHAIN:-nightly}"

for tool in "${AS}" "${AR}" "${RANLIB}" "${OBJCOPY}" "${OBJDUMP}" "${NM}" ; do
    command -v "${tool}" >/dev/null 2>&1 || fail "${tool} not found (apt install binutils-riscv64-linux-gnu)"
done
command -v rustup >/dev/null 2>&1 || command -v "${CARGO}" >/dev/null 2>&1 \
    || fail "cargo not found"

mkdir -p "${OUTPUT_DIR}"
rm -f "${OUTPUT_DIR}/libopenvm.a"

# --- 1. Rust accelerators --------------------------------------------------
echo "Building the accelerator staticlib for ${TARGET_NAME}..."
( cd "${ACCEL_DIR}" && rustup run "${TOOLCHAIN}" "${CARGO}" build --release \
    --target "${TARGET_JSON}" \
    -Z build-std=core,alloc,panic_abort -Z json-target-spec ) \
    || fail "cargo build failed"

RUST_LIB="${ACCEL_DIR}/target/${TARGET_NAME}/release/libopenvmaccel.a"
[ -f "${RUST_LIB}" ] || fail "${RUST_LIB} not produced"
cp "${RUST_LIB}" "${OUTPUT_DIR}/libopenvm.a"

# src/ecrecover.rs replaces openvm-eth's zkvm_secp256k1_ecrecover (see there
# for why). One crate graph cannot define an unmangled symbol twice, so ours is
# built as bflat_secp256k1_ecrecover: make openvm-eth's local, then give ours
# the interface name. Two passes, because objcopy matches --localize-symbol
# against the name after --redefine-sym.
"${OBJCOPY}" --localize-symbol=zkvm_secp256k1_ecrecover "${OUTPUT_DIR}/libopenvm.a" \
    || fail "objcopy failed"
"${OBJCOPY}" --redefine-sym=bflat_secp256k1_ecrecover=zkvm_secp256k1_ecrecover \
    "${OUTPUT_DIR}/libopenvm.a" || fail "objcopy failed"

# The archive exports far more than the interface. Two sources:
#
#   - The accelerated k256/p256 pull in the whole `openvm` guest runtime, which
#     brings its own entry point and libc-ish helpers - _start, mem* - and the
#     sys_alloc_aligned the bump allocator calls.
#   - `-Z build-std` compiles compiler_builtins for a target with no libm, so
#     it exports the entire C math surface (log, pow, sqrt, ... about 110
#     symbols) plus bcmp.
#
# Every one of those collides with the guest: musl defines the math surface and
# mem*, modules/zkvm_openvm/module.S defines _start, and bflat's rust_sys
# module wraps sys_alloc_aligned so OpenVM's bump allocator draws from pal's
# heap rather than opening a second one. A duplicate-symbol error is the good
# outcome; the bad one is this archive silently winning over the math surface
# that bflat's nofp module is supposed to divert.
#
# So rather than chase a list of collisions, localize everything that is not
# deliberately exported. What has to stay global:
#
#   zkvm_*, read_input, write_output   the interface itself
#   __sync_*                           the single-hart builtins (src/sync.rs)
#   *_extern_func_*, *_setup_*         OpenVM's curve/modulus glue: our
#                                      init.rs defines these and the
#                                      accelerated crates reference them from
#                                      other objects in this same archive
#   native_*, _critical_section_*      likewise internal, cross-object, and
#                                      not defined anywhere in the guest
#
# A new dependency that needs another global will fail the guest's link with an
# undefined reference, which is visible and fixable. The reverse - a new global
# quietly displacing one of the guest's - would not be.
KEEP_GLOBAL_RE='^(zkvm_|read_input$|write_output$|__sync_|native_|_critical_section_)|_extern_func_'
LOCALIZE="$("${NM}" --defined-only "${OUTPUT_DIR}/libopenvm.a" 2>/dev/null \
    | awk '$2 == "T" || $2 == "D" || $2 == "B" { print $3 }' \
    | grep -vE "${KEEP_GLOBAL_RE}" \
    | grep -vE '^(_RNv|_ZN|\$)' \
    | sort -u)"
[ -n "${LOCALIZE}" ] || fail "found nothing to localize - is ${NM} working?"
echo "Localizing $(echo "${LOCALIZE}" | wc -l | tr -d ' ') non-interface symbols"
printf '%s\n' "${LOCALIZE}" > "${OUTPUT_DIR}/localize.txt"
"${OBJCOPY}" --localize-symbols="${OUTPUT_DIR}/localize.txt" \
    "${OUTPUT_DIR}/libopenvm.a" || fail "objcopy failed"

# --- 2. Raw intrinsic shims ------------------------------------------------
echo "Assembling openvm_intrinsics.S..."
"${AS}" --march=rv64im --mabi=lp64 \
    "${ROOT_DIR}/src/openvm_intrinsics/openvm_intrinsics.S" \
    -o "${OUTPUT_DIR}/openvm_intrinsics.o" || fail "assembly failed"
# Clear the float-ABI marker so ld.lld accepts the object against the guest's
# soft-float crt1.o.
printf '\x00' | dd of="${OUTPUT_DIR}/openvm_intrinsics.o" bs=1 seek=48 count=1 conv=notrunc status=none

"${AR}" r "${OUTPUT_DIR}/libopenvm.a" "${OUTPUT_DIR}/openvm_intrinsics.o" || fail "ar failed"
"${RANLIB}" "${OUTPUT_DIR}/libopenvm.a" || fail "ranlib failed"

# --- 3. Prove the interface is complete ------------------------------------
# All 19 accelerators of the eth-act C interface plus the two IO entry points.
# The managed side (Nethermind.Zkvm.Abstractions) declares every one of these
# as [LibraryImport("__Internal")] with direct P/Invoke, so a missing symbol is
# not a slow fallback - it is an undefined reference in the guest's link.
STANDARD_SURFACE="
zkvm_keccak256 zkvm_sha256 zkvm_ripemd160 zkvm_modexp zkvm_blake2f
zkvm_secp256k1_verify zkvm_secp256k1_ecrecover zkvm_secp256r1_verify
zkvm_bn254_g1_add zkvm_bn254_g1_mul zkvm_bn254_pairing
zkvm_bls12_g1_add zkvm_bls12_g1_msm zkvm_bls12_g2_add zkvm_bls12_g2_msm
zkvm_bls12_pairing zkvm_bls12_map_fp_to_g1 zkvm_bls12_map_fp2_to_g2
zkvm_kzg_point_eval
read_input write_output
"
missing=""
defined="$("${NM}" --defined-only "${OUTPUT_DIR}/libopenvm.a" 2>/dev/null | awk '$2 == "T" { print $3 }')"
for sym in ${STANDARD_SURFACE} ; do
    echo "${defined}" | grep -qx "${sym}" || missing="${missing} ${sym}"
done
[ -z "${missing}" ] || fail "missing from the archive:${missing}"
[ "$(echo "${defined}" | grep -cx zkvm_secp256k1_ecrecover)" -eq 1 ] \
    || fail "zkvm_secp256k1_ecrecover is not defined exactly once"
echo "${defined}" | grep -qx bflat_secp256k1_ecrecover \
    && fail "bflat_secp256k1_ecrecover was not renamed"

# The reverse check: nothing the guest also defines may stay global, or the
# link fails on a duplicate symbol instead of a missing one.
leaked="$(echo "${defined}" | grep -xE '_start|__start|main|memcpy|memset|memmove|memcmp|sys_alloc_aligned' || true)"
[ -z "${leaked}" ] || fail "leaked as global: ${leaked}"
echo "Standard surface complete: 19 accelerators + read_input/write_output"

# --- 4. Prove the accelerators are really in there -------------------------
# custom-0 (0x0b) is keccak/sha2/u256; custom-1 (0x2b) is algebra/ecc, i.e. the
# curves. Zero of either means a silent fallback to portable Rust.
count_opcode() {
    "${OBJDUMP}" -d "$1" 2>/dev/null \
        | grep -oE '^ *[0-9a-f]+:\s+[0-9a-f]{8}' | awk '{print $2}' \
        | while read -r w ; do
            v=$((16#$w))
            [ $((v & 0x7f)) -eq "$2" ] && echo x
          done | wc -l
}
C0=$(count_opcode "${OUTPUT_DIR}/libopenvm.a" 11)
C1=$(count_opcode "${OUTPUT_DIR}/libopenvm.a" 43)
echo "OpenVM custom-0 instructions: ${C0}"
echo "OpenVM custom-1 instructions: ${C1}"
[ "${C0}" -gt 0 ] || fail "no custom-0 instructions - the hash accelerators did not activate"
[ "${C1}" -gt 0 ] || fail "no custom-1 instructions - the curve accelerators did not activate"

cp "${ROOT_DIR}/bflat-manifest.json" "${OUTPUT_DIR}/libopenvm.bflat.manifest"

echo "Build completed"
echo "Output: ${OUTPUT_DIR}/libopenvm.a"
echo "        ${OUTPUT_DIR}/libopenvm.bflat.manifest"
