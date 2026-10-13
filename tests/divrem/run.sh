#!/bin/bash
# SPDX-FileCopyrightText: 2026 Demerzel Solutions Limited
# SPDX-License-Identifier: MIT
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
python3 tests/divrem/generate.py "$out"
riscv64-linux-gnu-as -march=rv64im -mabi=lp64 "$out/guest.S" -o "$out/guest.o"
riscv64-linux-gnu-as -march=rv64im -mabi=lp64 src/openvm_intrinsics/openvm_intrinsics.S -o "$out/intrinsics.o"
riscv64-linux-gnu-ld --no-relax -Ttext=0x200800 -e _start "$out/guest.o" "$out/intrinsics.o" -o "$out/guest"
docker run --rm -v "$out:/vectors:ro" "${1:?runner image required}" /vectors/guest - /vectors/empty.raw > "$out/actual.txt"
diff -u "$out/expected.txt" "$out/actual.txt"
