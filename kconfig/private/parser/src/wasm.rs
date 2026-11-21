//! The exports of the WebAssembly module, with the calling convention of
//! `repository_ctx.execute_wasm`: the host writes the request into memory it
//! obtained from `allocate`, calls `run` with the request's address and
//! length and the addresses of two words to receive the response's address
//! and length, and reads the response back. The return code is 0; a failure
//! is an `error` response. Bazel instantiates the module per repository, so
//! nothing allocated here is freed.

use std::alloc::{Layout, alloc};

#[unsafe(no_mangle)]
pub extern "C" fn allocate(size: u32, align: u32) -> *mut u8 {
    let layout = match Layout::from_size_align(size.max(1) as usize, align.max(1) as usize) {
        Ok(layout) => layout,
        Err(_) => return std::ptr::null_mut(),
    };
    unsafe { alloc(layout) }
}

#[unsafe(no_mangle)]
pub extern "C" fn run(
    input: *const u8,
    input_len: u32,
    out_ptr: *mut *mut u8,
    out_len: *mut u32,
) -> u32 {
    let input = if input.is_null() {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(input, input_len as usize) }
    };
    let mut output = kconfig::entry::run(input);
    output.shrink_to_fit();
    let len = output.len();
    let ptr = output.leak().as_mut_ptr();
    unsafe {
        *out_ptr = ptr;
        *out_len = len as u32;
    }
    0
}
