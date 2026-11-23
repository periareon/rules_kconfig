//! The exports of the WebAssembly module, with the calling convention of
//! `repository_ctx.execute_wasm`: the host writes the request into memory it
//! obtained from `allocate`, calls `run` with the request's address and
//! length and the addresses of two words to receive the response's address
//! and length, and reads the response back. The return code is 0; a failure
//! is an `error` response. Bazel instantiates the module per repository, so
//! nothing allocated here is freed.
//!
//! The exports take raw addresses in the module's memory, which the host
//! owns: this is the other unsafe code of the module, with ffi.rs.
#![deny(clippy::undocumented_unsafe_blocks)]

use std::alloc::{Layout, alloc};

/// Memory for the host to write the request into; the host owns it.
#[unsafe(no_mangle)]
pub extern "C" fn allocate(size: u32, align: u32) -> *mut u8 {
    let layout = match Layout::from_size_align(size.max(1) as usize, align.max(1) as usize) {
        Ok(layout) => layout,
        Err(_) => return std::ptr::null_mut(),
    };
    // SAFETY: the layout is non-zero-sized (`size.max(1)`) and valid, as
    // `from_size_align` checked.
    unsafe { alloc(layout) }
}

/// Run a request: `input_len` bytes at `input`, from `allocate`. The
/// response's address and length are written to `out_ptr` and `out_len`.
///
/// # Safety
/// `input` is null or `input_len` readable bytes; `out_ptr` and `out_len`
/// are writable. The host upholds this through `repository_ctx.execute_wasm`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn run(
    input: *const u8,
    input_len: u32,
    out_ptr: *mut *mut u8,
    out_len: *mut u32,
) -> u32 {
    let input = if input.is_null() {
        &[][..]
    } else {
        // SAFETY: non-null, so `input_len` readable bytes per the contract.
        unsafe { std::slice::from_raw_parts(input, input_len as usize) }
    };
    let mut output = kconfig::entry::run(input);
    output.shrink_to_fit();
    let len = output.len();
    let ptr = output.leak().as_mut_ptr();
    // SAFETY: writable per the contract.
    unsafe {
        *out_ptr = ptr;
        *out_len = len as u32;
    }
    0
}
