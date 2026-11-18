#!/bin/bash
# Unit tests for platform/entry.S, the bflat entry point of OpenVM.
#
# The entry object is cross-compiled for riscv64 (glibc, static) and run
# under qemu-user, so the tests run the entry code on the REAL guest ISA.
# They moved here from bflat-riscv64 (src/bflat/modules/tests/run_tests.sh)
# together with the entry point.
#
# Requirements: gcc-riscv64-linux-gnu, clang, lld, qemu-user-static (or qemu-user).
#
# TEST_SKIP_FAULTS=1 skips the designed-fault (SIGSEGV) tests: qemu-user
# under nested emulation (Docker Rosetta on Apple silicon) hangs on guest
# faults instead of delivering the signal. CI on real x86_64 runs them.
#
# Copyright (C) 2026 Demerzel Solutions Limited (Nethermind)

set -u

TESTS_DIR="$(cd "$(dirname "$0")" ; pwd -P)"
PLATFORM_DIR="$(cd "${TESTS_DIR}/../../platform" ; pwd -P)"
OUT_DIR="${TESTS_DIR}/out"

CC="${CC:-riscv64-linux-gnu-gcc}"
OBJCOPY="${OBJCOPY:-${CC%gcc}objcopy}"

# Native riscv64 needs no emulator; anywhere else pick a qemu-user binary.
if [ "$(uname -m)" = "riscv64" ] ; then
	RUN=""
elif command -v qemu-riscv64-static > /dev/null 2>&1 ; then
	RUN="qemu-riscv64-static"
elif command -v qemu-riscv64 > /dev/null 2>&1 ; then
	RUN="qemu-riscv64"
else
	echo "error: need qemu-riscv64-static (apt install qemu-user-static)" >&2
	exit 1
fi

command -v "${CC}" > /dev/null 2>&1 || {
	echo "error: ${CC} not found (apt install gcc-riscv64-linux-gnu)" >&2
	exit 1
}

# -static -no-pie: deterministic addresses and no runtime library needs
# under qemu.
CFLAGS="-O1 -g -static -no-pie -std=gnu2x -I${TESTS_DIR}"

mkdir -p "${OUT_DIR}"
failures=0

for size in 8 16 24 32 ; do
	name="test_stack32_${size}"
	if ! clang --target=riscv32-unknown-elf -march=rv32im -mabi=ilp32 -DBSS_SIZE=${size} -c \
		"${TESTS_DIR}/stack32.S" -o "${OUT_DIR}/${name}.o" || \
		! ld.lld -T "${PLATFORM_DIR}/../platform32/openvm32.ld" \
		"${OUT_DIR}/${name}.o" -o "${OUT_DIR}/${name}" ; then
		echo "BUILD FAIL: ${name}"
		failures=$((failures + 1))
		continue
	fi
	stack_top=$("${CC%gcc}nm" "${OUT_DIR}/${name}" | awk '$3 == "_init_stack_top" { print $1 }')
	if [ -z "${stack_top}" ] || [ "$((0x${stack_top} & 15))" != 0 ] ; then
		echo "FAIL: ${name}: stack is not 16-byte aligned (${stack_top})"
		failures=$((failures + 1))
	else
		echo "PASS: ${name}"
	fi
done

# Per-suite wall-clock cap, so that a hang fails the run instead of sitting
# until the CI job's own timeout.
SUITE_TIMEOUT="${SUITE_TIMEOUT:-300}"

run_one()
{
	local name="$1" ; shift
	if ! "$@" -o "${OUT_DIR}/${name}" ; then
		echo "BUILD FAIL: ${name}"
		failures=$((failures + 1))
		return
	fi
	timeout -s KILL "${SUITE_TIMEOUT}" ${RUN} "${OUT_DIR}/${name}"
	local rc=$?
	if [ "${rc}" = "137" ] ; then
		echo "TIMEOUT (${SUITE_TIMEOUT}s): ${name}"
		failures=$((failures + 1))
	elif [ "${rc}" != "0" ] ; then
		failures=$((failures + 1))
	fi
}

# entry.S defines _start and calls __libc_start_main - both clash with
# crt1.o/libc in a hosted test binary. Rename them in a private copy of the
# object (the same --redefine-sym trick the bflat crt1 build uses), so the
# test drives the bootstrap explicitly while keeping a working libc
# underneath.
prepare_entry_obj()
{
	local obj="${OUT_DIR}/entry.o"
	${CC} -c "${PLATFORM_DIR}/entry.S" -o "${obj}" || return 1
	${OBJCOPY} \
		--redefine-sym _start=zkvm_module_start \
		--redefine-sym __libc_start_main=test_libc_start_main \
		"${obj}" || return 1
	echo "${obj}"
}

if ! obj="$(prepare_entry_obj)" ; then
	echo "BUILD FAIL: entry.S"
	exit 1
fi

# _start: the linker-script symbols it dereferences (_init_stack_top,
# _global_pointer) are pointed at real arrays in the test. The halt sequence
# after the start-up call is never reached - the stub exits first.
STACK_TOP="zkvm_test_stack+65536"
run_one "test_start_openvm" \
	${CC} ${CFLAGS} -DZKVM_MODULE_NAME="\"openvm\"" -DZKVM_ENTRY_NOOS=1 \
	"${TESTS_DIR}/test_entry.c" "${obj}" \
	-Wl,--defsym,_init_stack_top=${STACK_TOP} \
	-Wl,--defsym,_global_pointer=zkvm_test_gp

# __wrap_memcpy, __wrap_memmove and __wrap_memset, linked from the same
# renamed object.
run_one "test_mem_openvm" \
	${CC} ${CFLAGS} -DZKVM_MODULE_NAME="\"openvm\"" \
	"${TESTS_DIR}/test_mem.c" "${obj}" \
	-Wl,--defsym,_init_stack_top=zkvm_test_stack+16 \
	-Wl,--defsym,_global_pointer=zkvm_test_gp

echo "--------------------------------------------------"
if [ "${failures}" != "0" ] ; then
	echo "platform unit tests: ${failures} suite(s) FAILED"
	exit 1
fi
echo "platform unit tests: all suites passed"
exit 0
