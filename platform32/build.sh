#!/bin/bash
# Builds the OpenVM RV32 platform (OpenVM's `main` line) for bflat guests into
# the output directory (the first argument; default: output32/ in the
# repository):
#
#   - openvm32_entry.o: entry.S assembled; the _start of the guest and the halt protocol
#   - openvm32.ld: the memory map (linker script)
#   - openvm32.bflat.manifest: the platform manifest (docs/manifest.md in bflat-riscv64)
#
# The counterpart of platform/build.sh; build/build.sh calls it with ARCH=riscv32.
set -e

fail() { echo "$@" >&2; exit 1; }

PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:-$(cd "${PLATFORM_DIR}/.." && pwd)/output32}"
AS="${AS:-riscv64-linux-gnu-as}"

command -v "${AS}" >/dev/null 2>&1 || fail "${AS} not found (apt install binutils-riscv64-linux-gnu)"
mkdir -p "${OUTPUT_DIR}"

"${AS}" --march=rv32im --mabi=ilp32 "${PLATFORM_DIR}/entry.S" -o "${OUTPUT_DIR}/openvm32_entry.o" \
    || fail "failed to assemble entry.S"

for f in openvm32.ld openvm32.bflat.manifest ; do
    cp "${PLATFORM_DIR}/${f}" "${OUTPUT_DIR}/${f}" || fail "failed to copy ${f}"
done

echo "Platform: ${OUTPUT_DIR}/openvm32_entry.o openvm32.ld openvm32.bflat.manifest"
