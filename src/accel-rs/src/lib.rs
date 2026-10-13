//! OpenVM guest support library for bflat: the
//! [eth-act zkVM accelerator](https://github.com/eth-act/zkvm-standards/tree/main/standards/c-interface-accelerators)
//! and [IO](https://github.com/eth-act/zkvm-standards/tree/main/standards/io-interface)
//! C interfaces, packaged as a staticlib.
//!
//! A C#/NativeAOT guest cannot reach OpenVM's accelerators the way Rust guests
//! do - by swapping crypto crates through `[patch.crates-io]` - so it goes
//! through the C ABI instead. All 19 accelerator entry points but
//! `zkvm_secp256k1_ecrecover` come from OpenVM's own `openvm-accelerators`
//! crate; this crate replaces that one (`ecrecover`, see there for why) and
//! contributes the three things that crate leaves to the program:
//!
//! 1. `init` - the moduli, complex extensions and curves the accelerated
//!    arithmetic is instantiated over. `cargo openvm` generates this for a
//!    Rust guest; ours has no cargo build to generate it.
//! 2. `io` - `read_input` / `write_output`, which have no OpenVM
//!    implementation anywhere upstream.
//! 3. `sync` - the `__sync_*` builtins an rv64im target needs and no
//!    toolchain supplies. See that module; it is a link-time requirement of
//!    the accelerated curves, not an accelerator itself.
//! 4. The staticlib packaging itself, plus the symbol localization in
//!    `build/build.sh` that keeps OpenVM's guest runtime from colliding with
//!    the C# guest's entry point, musl and pal's allocator.
//!
//! MUST be built for a target whose `os` is `openvm` (see
//! riscv64im-openvm-elf.json). OpenVM gates every accelerated path behind
//! `cfg(any(openvm_intrinsics, target_os = "openvm"))`; on any other target
//! this still compiles and links, but each primitive silently falls back to
//! portable Rust and the point is lost.
#![no_std]

extern crate alloc;

mod ecrecover;
mod init;
mod io;
mod secp256k1_tables;
mod sync;

// Re-export so the accelerators' `#[no_mangle]` symbols are reachable roots of
// this staticlib and survive LTO. build/build.sh asserts each one is present
// and global in the finished archive.
pub use openvm_accelerators::*;

// No `#[global_allocator]` and no `#[panic_handler]` here: the accelerated
// crates bring the whole `openvm` guest runtime, which already provides both,
// and a second definition of either is a hard error.
//
// That runtime's allocator is a bump pointer over `sys_alloc_aligned`, which
// bflat's `rust_sys` module wraps (`--wrap=sys_alloc_aligned`) and routes into
// pal's heap - so the Rust side and the C# guest share one heap instead of the
// staticlib carving out a second, invisible one.
