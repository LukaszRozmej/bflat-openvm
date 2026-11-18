//! OpenVM implementation of the
//! [eth-act zkVM IO interface](https://github.com/eth-act/zkvm-standards/tree/main/standards/io-interface)
//! (`zkvm_io.h`): `read_input` and `write_output`.
//!
//! Both sides map onto OpenVM's own guest IO, the same way ere-guests'
//! `ere_platform_openvm` does.

use core::ptr::addr_of_mut;

/// Cached input. `read_input` is specified to be idempotent, and OpenVM's
/// `read_vec` is not - it consumes the next hint stream record - so the first
/// call keeps the buffer and every later call hands back the same pointer.
///
/// A plain `static mut` is sound here: an OpenVM guest is single-threaded by
/// construction (there is no thread creation instruction), so no two callers
/// can ever race.
static mut INPUT: Option<(*const u8, usize)> = None;

#[cfg(not(target_arch = "riscv32"))]
fn read_bytes() -> (*const u8, usize) {
    let input = openvm::io::read_vec().leak();
    (input.as_mut_ptr(), input.len())
}

#[cfg(target_arch = "riscv32")]
fn read_bytes() -> (*const u8, usize) {
    use alloc::boxed::Box;
    use openvm_algebra_guest::openvm_rv32im_guest::{hint_buffer_chunked, hint_input};

    hint_input();
    let len = openvm::io::read_u32() as usize;
    // Trusted-input items are eight-byte aligned relative to the payload. Read
    // directly into storage with that alignment so the guest can use them in place.
    let words = Box::leak(Box::<[u64]>::new_uninit_slice(len.div_ceil(8)));
    let data = words.as_mut_ptr().cast::<u8>();
    hint_buffer_chunked(data, len.div_ceil(4));
    (data, len)
}

/// `void read_input(const uint8_t** buf_ptr, size_t* buf_size)`.
///
/// The first call retains the buffer for the life of the guest.
#[no_mangle]
pub unsafe extern "C" fn read_input(buf_ptr: *mut *const u8, buf_size: *mut usize) {
    assert!(!buf_ptr.is_null() && !buf_size.is_null(), "read_input: NULL out-parameter");

    let slot = &mut *addr_of_mut!(INPUT);
    let (data, len) = *slot.get_or_insert_with(read_bytes);

    buf_ptr.write(data);
    buf_size.write(len);
}

/// OpenVM's user public output is a byte-addressed buffer written a u64 at a
/// time by the `reveal` instruction, but only the first 32 bytes are
/// guaranteed to exist: that is what the default app configuration allocates,
/// and it is the window `reveal_bytes32` - the API OpenVM steers guests
/// towards - covers.
///
/// ere-guests takes the same 32-byte limit and simply asserts on anything
/// longer. We keep the limit but implement the standard's actual contract
/// inside it, so that two 16-byte writes are observed as one 32-byte output
/// rather than the second overwriting the first.
const PUBLIC_OUTPUT_CAPACITY: usize = 32;

static mut OUTPUT: [u8; PUBLIC_OUTPUT_CAPACITY] = [0u8; PUBLIC_OUTPUT_CAPACITY];
static mut OUTPUT_LEN: usize = 0;

/// `void write_output(const uint8_t* output, size_t size)`.
///
/// Appends to the public output; multiple calls concatenate.
///
/// Panics if the total would exceed 32 bytes. That is a hard limit of the
/// target, not a policy choice: bytes past the end of the public-values buffer
/// have nowhere to go, and silently dropping them would produce a proof that
/// attests to less than the guest believes it published. Guests with more to
/// say should publish a hash of it, which is what OpenVM recommends anyway.
#[no_mangle]
pub unsafe extern "C" fn write_output(output: *const u8, size: usize) {
    if size == 0 {
        return;
    }
    assert!(!output.is_null(), "write_output: NULL buffer");

    let len = *addr_of_mut!(OUTPUT_LEN);
    assert!(
        size <= PUBLIC_OUTPUT_CAPACITY - len,
        "write_output: OpenVM's public output holds 32 bytes; publish a hash instead"
    );

    let buf = &mut *addr_of_mut!(OUTPUT);
    core::ptr::copy_nonoverlapping(output, buf.as_mut_ptr().add(len), size);
    *addr_of_mut!(OUTPUT_LEN) = len + size;

    // Re-publish the whole window rather than just the new bytes: a write can
    // land in the middle of a u64, and `reveal` writes whole words.
    openvm::io::reveal_bytes32(*buf);
}
