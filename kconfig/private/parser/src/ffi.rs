//! The binding to shim.c, both ways: the parsers' entry points, and the host
//! functions they call back into, served from the session of the call.
//!
//! The kernel's structs stay opaque; shim.h is the whole surface, written
//! out here by hand, so that one binding serves wasm32 and the 64-bit hosts.
//! The parser of each kernel release is linked in once, behind a table of
//! entry points (`struct kconfig_shim`); `kconfig_parsers` lists them newest
//! first, and `select` makes one of them the parser of the call.

use std::cell::{Cell, RefCell};
use std::ffi::CStr;

pub use libc::free;
use libc::{c_char, c_int, malloc};

use crate::host::{ReadError, Session};

#[repr(C)]
pub struct symbol {
    _private: [u8; 0],
}

#[repr(C)]
pub struct menu {
    _private: [u8; 0],
}

/// The entry points of the parser of one kernel release: `struct
/// kconfig_shim` of shim.h, field for field.
#[repr(C)]
pub struct Shim {
    pub version: *const c_char,
    pub parse: unsafe extern "C" fn(filename: *const c_char) -> c_int,
    pub diagnostics: unsafe extern "C" fn(len: *mut usize) -> *const c_char,
    pub filenames: unsafe extern "C" fn(count: *mut usize) -> *const *const c_char,
    pub load_config: unsafe extern "C" fn(text: *const c_char, len: usize) -> c_int,
    pub config_contents: unsafe extern "C" fn(len: *mut usize) -> *const c_char,
    pub menu_symbols: unsafe extern "C" fn(count: *mut usize) -> *mut *mut symbol,
    pub symbol_name: unsafe extern "C" fn(sym: *mut symbol) -> *const c_char,
    pub symbol_type: unsafe extern "C" fn(sym: *mut symbol) -> c_int,
    pub symbol_str_value: unsafe extern "C" fn(sym: *mut symbol) -> *const c_char,
    pub symbol_has_user_value: unsafe extern "C" fn(sym: *mut symbol) -> c_int,
    pub symbol_visible: unsafe extern "C" fn(sym: *mut symbol) -> c_int,
    pub symbol_user_tri: unsafe extern "C" fn(sym: *mut symbol) -> c_int,
    pub symbol_user_str: unsafe extern "C" fn(sym: *mut symbol) -> *const c_char,
    pub symbol_nodes: unsafe extern "C" fn(sym: *mut symbol, count: *mut usize) -> *mut *mut menu,
    pub menu_filename: unsafe extern "C" fn(menu: *mut menu) -> *const c_char,
    pub menu_lineno: unsafe extern "C" fn(menu: *mut menu) -> c_int,
}

unsafe impl Sync for Shim {}

unsafe extern "C" {
    /// The tables of every release linked in, newest first, then null
    /// (parsers.c).
    static kconfig_parsers: [*const Shim; 0];
}

/// The parsers linked in, newest first.
pub fn parsers() -> Vec<&'static Shim> {
    let mut found = Vec::new();
    let mut entry = std::ptr::addr_of!(kconfig_parsers) as *const *const Shim;
    unsafe {
        while !(*entry).is_null() {
            found.push(&**entry);
            entry = entry.add(1);
        }
    }
    found
}

/// The kernel releases of the parsers linked in, newest first.
pub fn versions() -> Vec<Vec<u8>> {
    parsers()
        .iter()
        .map(|shim| unsafe { bytes_of(shim.version) })
        .collect()
}

thread_local! {
    /// The parser of the call in progress.
    static SHIM: Cell<Option<&'static Shim>> = const { Cell::new(None) };
}

/// Make the parser of `version` the one of the call, or the newest when
/// none is named.
pub fn select(version: Option<&[u8]>) -> Result<&'static Shim, String> {
    let parsers = parsers();
    let shim = match version {
        None => parsers.first().copied(),
        Some(wanted) => parsers
            .iter()
            .copied()
            .find(|shim| unsafe { bytes_of(shim.version) } == wanted),
    };
    let shim = shim.ok_or_else(|| {
        format!(
            "this build of the parser has the kernel's Kconfig of {}, not of {}",
            versions()
                .iter()
                .map(|v| String::from_utf8_lossy(v).into_owned())
                .collect::<Vec<_>>()
                .join(" and "),
            String::from_utf8_lossy(version.unwrap_or_default())
        )
    })?;
    SHIM.with(|current| current.set(Some(shim)));
    Ok(shim)
}

/// The parser of the call.
///
/// # Panics
/// Before `select`.
pub fn shim() -> &'static Shim {
    SHIM.with(|current| current.get().expect("no parser selected"))
}

/// The bytes of a C string.
///
/// # Safety
/// `ptr` is NUL-terminated, or null, which is an empty string.
pub unsafe fn bytes_of(ptr: *const c_char) -> Vec<u8> {
    if ptr.is_null() {
        return Vec::new();
    }
    unsafe { CStr::from_ptr(ptr) }.to_bytes().to_vec()
}

/// The bytes of a buffer of `len` bytes.
///
/// # Safety
/// `ptr` points at `len` readable bytes, or is null.
pub unsafe fn bytes_of_len(ptr: *const c_char, len: usize) -> Vec<u8> {
    if ptr.is_null() {
        return Vec::new();
    }
    unsafe { std::slice::from_raw_parts(ptr as *const u8, len) }.to_vec()
}

/// A `malloc`ed, NUL-terminated copy, for C to `free`.
fn c_copy(bytes: &[u8]) -> *mut c_char {
    unsafe {
        let ptr = malloc(bytes.len() + 1) as *mut u8;
        if ptr.is_null() {
            return ptr as *mut c_char;
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr, bytes.len());
        *ptr.add(bytes.len()) = 0;
        ptr as *mut c_char
    }
}

thread_local! {
    /// The session of the call in progress, which the host functions serve.
    /// Borrowed only for the duration of a lookup, never across a call into
    /// the parser, which calls back in.
    static SESSION: RefCell<Option<Session>> = const { RefCell::new(None) };
}

/// Make `session` the one the parser's host functions serve.
pub fn install(session: Session) {
    SESSION.with(|current| *current.borrow_mut() = Some(session));
}

/// Take the installed session back.
pub fn take() -> Option<Session> {
    SESSION.with(|current| current.borrow_mut().take())
}

/// Look something up in the installed session.
///
/// # Panics
/// Without a session installed.
pub fn with<R>(f: impl FnOnce(&mut Session) -> R) -> R {
    SESSION.with(|current| f(current.borrow_mut().as_mut().expect("no session installed")))
}

fn with_current<R>(default: R, f: impl FnOnce(&mut Session) -> R) -> R {
    SESSION.with(|current| match current.borrow_mut().as_mut() {
        Some(session) => f(session),
        None => default,
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn kconfig_rust_read(
    path: *const c_char,
    len: *mut usize,
    status: *mut c_int,
) -> *mut c_char {
    let path = unsafe { bytes_of(path) };
    let (bytes, code) = with_current((Vec::new(), 1), |session| match session.host.read(&path) {
        Ok(bytes) => (bytes, 0),
        Err(ReadError::NotFound) => (Vec::new(), 1),
        Err(ReadError::IsDirectory) => (Vec::new(), 2),
    });
    unsafe {
        *status = code;
        *len = bytes.len();
    }
    c_copy(&bytes)
}

#[unsafe(no_mangle)]
pub extern "C" fn kconfig_rust_isdir(path: *const c_char) -> c_int {
    let path = unsafe { bytes_of(path) };
    with_current(false, |session| session.host.isdir(&path)) as c_int
}

#[unsafe(no_mangle)]
pub extern "C" fn kconfig_rust_exists(path: *const c_char) -> c_int {
    let path = unsafe { bytes_of(path) };
    with_current(false, |session| session.host.exists(&path)) as c_int
}

#[unsafe(no_mangle)]
pub extern "C" fn kconfig_rust_getenv(name: *const c_char) -> *mut c_char {
    let name = unsafe { bytes_of(name) };
    match with_current(None, |session| session.getenv(&name)) {
        Some(value) => c_copy(&value),
        None => std::ptr::null_mut(),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn kconfig_rust_shell(command: *const c_char, len: *mut usize) -> *mut c_char {
    let command = unsafe { bytes_of(command) };
    let output = with_current(b"n".to_vec(), |session| session.shell(&command));
    unsafe {
        *len = output.len();
    }
    c_copy(&output)
}
