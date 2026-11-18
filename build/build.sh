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
#
# ARCH=riscv32 builds libopenvm32.a into output32/ instead: the same layers
# for OpenVM's RV32 line (`main`), with src/accel-rs32 and platform32/.
set -e

fail() { echo "$@" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARCH="${ARCH:-riscv64}"
case "${ARCH}" in
    riscv64)
        OUTPUT_DIR="${ROOT_DIR}/output"
        ACCEL_DIR="${ROOT_DIR}/src/accel-rs"
        TARGET_NAME="riscv64im-openvm-elf"
        TARGET_ARGS=(--target "${ACCEL_DIR}/${TARGET_NAME}.json" -Z json-target-spec)
        LIB_NAME="libopenvm"
        MARCH="rv64im" ; MABI="lp64" ; ASFLAGS=""
        PLATFORM_DIR="${ROOT_DIR}/platform"
        MANIFEST="${ROOT_DIR}/bflat-manifest.json"
        ;;
    riscv32)
        OUTPUT_DIR="${ROOT_DIR}/output32"
        ACCEL_DIR="${ROOT_DIR}/src/accel-rs32"
        # rustc's own target for RV32IM zkVMs. Its os is "zkvm", the os that
        # OpenVM's `main` gates its guest code on, where the RV64 line uses
        # "openvm"; src/accel-rs32/.cargo/config.toml lowers its atomics.
        TARGET_NAME="riscv32im-risc0-zkvm-elf"
        TARGET_ARGS=(--target "${TARGET_NAME}")
        LIB_NAME="libopenvm32"
        # The division hint is RV64 only (see openvm_intrinsics.S).
        MARCH="rv32im" ; MABI="ilp32" ; ASFLAGS="--defsym OPENVM_RV32=1"
        PLATFORM_DIR="${ROOT_DIR}/platform32"
        MANIFEST="${ROOT_DIR}/bflat-manifest32.json"
        ;;
    *) fail "ARCH must be riscv64 or riscv32, not ${ARCH}" ;;
esac
LIB="${OUTPUT_DIR}/${LIB_NAME}.a"
# openvm-eth's develop-v2.1.0 as src/accel-rs/Cargo.lock pins it. The RV32
# build takes openvm-accelerators from a checkout of it (src/accel-rs32/Cargo.toml).
OPENVM_ETH_REV="${OPENVM_ETH_REV:-fd54306404e9dd120a520c806d8c8218b4a18248}"

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
rm -f "${LIB}"

if [ "${ARCH}" = riscv32 ] ; then
    ETH_DIR="${ROOT_DIR}/tmp/openvm-eth"
    if [ ! -d "${ETH_DIR}/.git" ] ; then
        git clone --filter=blob:none https://github.com/axiom-crypto/openvm-eth.git "${ETH_DIR}" \
            || fail "failed to clone openvm-eth"
    fi
    git -C "${ETH_DIR}" checkout -q --force "${OPENVM_ETH_REV}" \
        || fail "failed to check out openvm-eth ${OPENVM_ETH_REV}"
    # Every OpenVM crate of its workspace from `main`, the RV32 line, and its
    # guest code gated on the os of that line.
    sed -i -E '/openvm-org\/openvm\.git/ s/branch = "develop-v2[^"]*"/branch = "main"/' "${ETH_DIR}/Cargo.toml"
    if grep -q 'openvm-org/openvm.git.*branch = "develop' "${ETH_DIR}/Cargo.toml" ; then
        fail "openvm-eth still pins an OpenVM crate to the RV64 line"
    fi
    find "${ETH_DIR}/crates" \( -name '*.rs' -o -name Cargo.toml \) \
        -exec sed -i 's/target_os = "openvm"/target_os = "zkvm"/g' {} +
fi

# --- 1. Rust accelerators --------------------------------------------------
echo "Building the accelerator staticlib for ${TARGET_NAME}..."
( cd "${ACCEL_DIR}" && rustup run "${TOOLCHAIN}" "${CARGO}" build --release \
    "${TARGET_ARGS[@]}" -Z build-std=core,alloc,panic_abort ) \
    || fail "cargo build failed"

RUST_LIB="${ACCEL_DIR}/target/${TARGET_NAME}/release/libopenvmaccel.a"
[ -f "${RUST_LIB}" ] || fail "${RUST_LIB} not produced"
cp "${RUST_LIB}" "${LIB}"

# src/ecrecover.rs replaces openvm-eth's zkvm_secp256k1_ecrecover (see there
# for why). One crate graph cannot define an unmangled symbol twice, so ours is
# built as bflat_secp256k1_ecrecover: make openvm-eth's local, then give ours
# the interface name. Two passes, because objcopy matches --localize-symbol
# against the name after --redefine-sym.
"${OBJCOPY}" --localize-symbol=zkvm_secp256k1_ecrecover "${LIB}" \
    || fail "objcopy failed"
"${OBJCOPY}" --redefine-sym=bflat_secp256k1_ecrecover=zkvm_secp256k1_ecrecover \
    "${LIB}" || fail "objcopy failed"

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
# mem*, platform/entry.S defines _start, and bflat's rust_sys
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
LOCALIZE="$("${NM}" --defined-only "${LIB}" 2>/dev/null \
    | awk '$2 == "T" || $2 == "D" || $2 == "B" { print $3 }' \
    | grep -vE "${KEEP_GLOBAL_RE}" \
    | grep -vE '^(_RNv|_ZN|\$)' \
    | sort -u)"
[ -n "${LOCALIZE}" ] || fail "found nothing to localize - is ${NM} working?"
echo "Localizing $(echo "${LOCALIZE}" | wc -l | tr -d ' ') non-interface symbols"
printf '%s\n' "${LOCALIZE}" > "${OUTPUT_DIR}/localize.txt"
"${OBJCOPY}" --localize-symbols="${OUTPUT_DIR}/localize.txt" \
    "${LIB}" || fail "objcopy failed"

# --- 2. Raw intrinsic shims ------------------------------------------------
echo "Assembling openvm_intrinsics.S..."
"${AS}" --march="${MARCH}" --mabi="${MABI}" ${ASFLAGS} \
    "${ROOT_DIR}/src/openvm_intrinsics/openvm_intrinsics.S" \
    -o "${OUTPUT_DIR}/openvm_intrinsics.o" || fail "assembly failed"
# Clear the float-ABI marker so ld.lld accepts the object against the guest's
# soft-float crt1.o. (e_flags is at 0x30 in ELF64; ilp32 sets no float bits.)
if [ "${ARCH}" = riscv64 ] ; then
    printf '\x00' | dd of="${OUTPUT_DIR}/openvm_intrinsics.o" bs=1 seek=48 count=1 conv=notrunc status=none
fi

"${AR}" r "${LIB}" "${OUTPUT_DIR}/openvm_intrinsics.o" || fail "ar failed"
"${RANLIB}" "${LIB}" || fail "ranlib failed"

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
defined="$("${NM}" --defined-only "${LIB}" 2>/dev/null | awk '$2 == "T" { print $3 }')"
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
C0=$(count_opcode "${LIB}" 11)
C1=$(count_opcode "${LIB}" 43)
echo "OpenVM custom-0 instructions: ${C0}"
echo "OpenVM custom-1 instructions: ${C1}"
[ "${C0}" -gt 0 ] || fail "no custom-0 instructions - the hash accelerators did not activate"
[ "${C1}" -gt 0 ] || fail "no custom-1 instructions - the curve accelerators did not activate"

cp "${MANIFEST}" "${OUTPUT_DIR}/${LIB_NAME}.bflat.manifest"

# The entry point, the memory map and the platform manifest (platform/).
AS="${AS}" "${PLATFORM_DIR}/build.sh" "${OUTPUT_DIR}" || fail "platform build failed"

echo "Build completed"
echo "Output: ${LIB}"
echo "        ${OUTPUT_DIR}/${LIB_NAME}.bflat.manifest"
