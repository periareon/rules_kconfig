//! The binding to shim.c, both ways: the parsers' entry points, and the host
//! functions they call back into, served from the session of the call.
//!
//! The kernel's structs stay opaque; shim.h is the whole surface, written
//! out here by hand, so that one binding serves wasm32 and the 64-bit hosts.
//! The parser of each kernel release is linked in once, behind a table of
//! entry points (`struct kconfig_shim`); `kconfig_parsers` lists them newest
//! first, and `select` makes one of them the parser of the call.
//!
//! This is the crate's unsafe code (lib.rs denies it elsewhere): the raw
//! table stays private, and the rest of the crate reaches the parser through
//! the safe methods of `Shim`, `Symbol` and `Menu`. What makes them sound is
//! how the parser keeps its state: in globals, for the life of the process,
//! with one parse per process (shim.h). So a symbol or menu the parser hands
//! out stays valid, and a handle carries the parser it came from, so that it
//! is only ever read through that parser's accessors.
#![allow(unsafe_code)]

use std::cell::{Cell, RefCell};
use std::ffi::CStr;

use libc::{c_char, c_int, free, malloc};

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
/// kconfig_shim` of shim.h, field for field. The methods below are the
/// fields, made safe.
#[repr(C)]
pub struct Shim {
    version: *const c_char,
    parse: unsafe extern "C" fn(filename: *const c_char) -> c_int,
    diagnostics: unsafe extern "C" fn(len: *mut usize) -> *const c_char,
    filenames: unsafe extern "C" fn(count: *mut usize) -> *const *const c_char,
    load_config: unsafe extern "C" fn(text: *const c_char, len: usize) -> c_int,
    config_contents: unsafe extern "C" fn(len: *mut usize, write_invisible: c_int) -> *const c_char,
    menu_symbols: unsafe extern "C" fn(count: *mut usize) -> *mut *mut symbol,
    symbol_name: unsafe extern "C" fn(sym: *mut symbol) -> *const c_char,
    symbol_type: unsafe extern "C" fn(sym: *mut symbol) -> c_int,
    symbol_str_value: unsafe extern "C" fn(sym: *mut symbol) -> *const c_char,
    symbol_has_user_value: unsafe extern "C" fn(sym: *mut symbol) -> c_int,
    symbol_visible: unsafe extern "C" fn(sym: *mut symbol) -> c_int,
    symbol_written: unsafe extern "C" fn(sym: *mut symbol) -> c_int,
    symbol_user_tri: unsafe extern "C" fn(sym: *mut symbol) -> c_int,
    symbol_user_str: unsafe extern "C" fn(sym: *mut symbol) -> *const c_char,
    symbol_nodes: unsafe extern "C" fn(sym: *mut symbol, count: *mut usize) -> *mut *mut menu,
    menu_filename: unsafe extern "C" fn(menu: *mut menu) -> *const c_char,
    menu_lineno: unsafe extern "C" fn(menu: *mut menu) -> c_int,
}

// SAFETY: `kconfig_parsers` is parsers.c's array of pointers to the
// `kconfig_shim_vtable` of each release linked in, newest first, ending in
// NULL; the tables are `const` statics, so the references `parsers` makes of
// them are good for the process.
unsafe extern "C" {
    static kconfig_parsers: [*const Shim; 0];
}

/// The parsers linked in, newest first.
pub fn parsers() -> Vec<&'static Shim> {
    let mut found = Vec::new();
    let mut entry = std::ptr::addr_of!(kconfig_parsers) as *const *const Shim;
    // SAFETY: the array is NULL-terminated and its entries point at static
    // tables (see the `extern` block).
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
    parsers().iter().map(|shim| shim.version()).collect()
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
            .find(|shim| shim.version() == wanted),
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

impl Shim {
    /// The kernel release, `6.12`, as `kconfig_version` names it.
    pub fn version(&self) -> Vec<u8> {
        // SAFETY: shim.c sets `version` to a string literal.
        unsafe { bytes_of(self.version) }
    }

    /// Parse the tree rooted at `filename`: 0 on success; 1 when the root
    /// cannot be opened; 2 when the parse failed, with the message in
    /// `diagnostics`; 3 when a tree was parsed already.
    pub fn parse(&self, filename: &CStr) -> c_int {
        // SAFETY: `CStr` guarantees the terminating NUL, and the parser reads
        // the name only during the call.
        unsafe { (self.parse)(filename.as_ptr()) }
    }

    /// What the parser printed to stderr.
    pub fn diagnostics(&self) -> Vec<u8> {
        let mut len = 0usize;
        // SAFETY: `len` is a local for the parser to write; the buffer
        // returned is the parser's own, of `len` bytes, or NULL.
        unsafe { bytes_of_len((self.diagnostics)(&mut len), len) }
    }

    /// The Kconfig files read, in order.
    pub fn filenames(&self) -> Vec<Vec<u8>> {
        let mut count = 0usize;
        // SAFETY: `count` is a local for the parser to write; the array
        // returned is the parser's own, of `count` NUL-terminated strings,
        // kept with the rest of its state.
        unsafe {
            let items = (self.filenames)(&mut count);
            (0..count).map(|i| bytes_of(*items.add(i))).collect()
        }
    }

    /// `conf_read` of a `.config` given as text; whether it succeeded.
    pub fn load_config(&self, text: &[u8]) -> bool {
        // SAFETY: `text` is `len` readable bytes, and the parser copies what
        // it keeps during the call.
        unsafe { (self.load_config)(text.as_ptr().cast(), text.len()) == 0 }
    }

    /// The `.config` `conf_write` writes, without its heading, and with the
    /// symbols it would leave out when `write_invisible`; None on failure.
    pub fn config_contents(&self, write_invisible: bool) -> Option<Vec<u8>> {
        let mut len = 0usize;
        // SAFETY: `len` is a local for the parser to write; the buffer
        // returned is the parser's own, of `len` bytes, or NULL on failure,
        // which `bytes_of_len` takes for empty, so NULL is checked first.
        unsafe {
            let ptr = (self.config_contents)(&mut len, c_int::from(write_invisible));
            if ptr.is_null() {
                return None;
            }
            Some(bytes_of_len(ptr, len))
        }
    }

    /// The symbol of every menu node, depth first in the order of the tree,
    /// with repeats and without choices.
    pub fn menu_symbols(&'static self) -> Vec<Symbol> {
        let mut count = 0usize;
        // SAFETY: `count` is a local for the parser to write; the array is
        // `malloc`ed for the caller to `free` (shim.h), and holds `count`
        // symbols of the parser's tree.
        let ptrs = unsafe { take_array((self.menu_symbols)(&mut count), count) };
        ptrs.into_iter()
            .map(|ptr| Symbol { shim: self, ptr })
            .collect()
    }
}

/// A symbol of a parser's tree (see the module for why reading it is safe).
#[derive(Clone, Copy)]
pub struct Symbol {
    shim: &'static Shim,
    ptr: *mut symbol,
}

impl Symbol {
    /// What tells two handles to the same symbol apart from two symbols.
    pub fn id(&self) -> usize {
        self.ptr as usize
    }

    /// One of the parser's accessors, applied to the symbol.
    fn get<R>(&self, accessor: unsafe extern "C" fn(*mut symbol) -> R) -> R {
        // SAFETY: `accessor` is one of `self.shim`'s, and `ptr` is a symbol
        // of that parser's tree, which lives as long as the process.
        unsafe { accessor(self.ptr) }
    }

    /// The name, without `CONFIG_`.
    pub fn name(&self) -> Vec<u8> {
        let name = self.get(self.shim.symbol_name);
        // SAFETY: the parser's strings are NUL-terminated, or NULL.
        unsafe { bytes_of(name) }
    }

    /// The type: UNKNOWN 0, BOOL 1, TRISTATE 2, STRING 3, INT 4, HEX 5.
    pub fn type_(&self) -> c_int {
        self.get(self.shim.symbol_type)
    }

    /// The value as `conf` writes it, calculated.
    pub fn str_value(&self) -> Vec<u8> {
        let value = self.get(self.shim.symbol_str_value);
        // SAFETY: the parser's strings are NUL-terminated, or NULL.
        unsafe { bytes_of(value) }
    }

    /// Whether a `.config` set the symbol.
    pub fn has_user_value(&self) -> bool {
        self.get(self.shim.symbol_has_user_value) != 0
    }

    /// Whether a `.config` can set the symbol: it has a prompt whose
    /// condition holds.
    pub fn visible(&self) -> bool {
        self.get(self.shim.symbol_visible) != 0
    }

    /// Whether the Kconfig tools write the symbol to `.config` and
    /// `autoconf.h`: it is visible or a default applies. One they do not
    /// write has no value; `str_value` is the type's seed (`0` for an
    /// `int`), not a setting.
    pub fn written(&self) -> bool {
        self.get(self.shim.symbol_written) != 0
    }

    /// The user value of a bool or tristate: 0, 1 or 2.
    pub fn user_tri(&self) -> c_int {
        self.get(self.shim.symbol_user_tri)
    }

    /// The user value of any other type.
    pub fn user_str(&self) -> Vec<u8> {
        let value = self.get(self.shim.symbol_user_str);
        // SAFETY: the parser's strings are NUL-terminated, or NULL.
        unsafe { bytes_of(value) }
    }

    /// The menu nodes defining the symbol.
    pub fn nodes(&self) -> Vec<Menu> {
        let mut count = 0usize;
        // SAFETY: as `get`, with `count` a local for the parser to write; the
        // array is `malloc`ed for the caller to `free` (shim.h), and holds
        // `count` menus of the parser's tree.
        let ptrs = unsafe { take_array((self.shim.symbol_nodes)(self.ptr, &mut count), count) };
        ptrs.into_iter()
            .map(|ptr| Menu {
                shim: self.shim,
                ptr,
            })
            .collect()
    }
}

/// A menu node of a parser's tree (see the module for why reading it is
/// safe).
#[derive(Clone, Copy)]
pub struct Menu {
    shim: &'static Shim,
    ptr: *mut menu,
}

impl Menu {
    /// One of the parser's accessors, applied to the menu.
    fn get<R>(&self, accessor: unsafe extern "C" fn(*mut menu) -> R) -> R {
        // SAFETY: `accessor` is one of `self.shim`'s, and `ptr` is a menu of
        // that parser's tree, which lives as long as the process.
        unsafe { accessor(self.ptr) }
    }

    /// The Kconfig file defining the node.
    pub fn filename(&self) -> Vec<u8> {
        let name = self.get(self.shim.menu_filename);
        // SAFETY: the parser's strings are NUL-terminated, or NULL.
        unsafe { bytes_of(name) }
    }

    /// The line of `filename`.
    pub fn lineno(&self) -> c_int {
        self.get(self.shim.menu_lineno)
    }
}

/// The bytes of a C string.
///
/// # Safety
/// `ptr` is NUL-terminated, or null, which is an empty string.
unsafe fn bytes_of(ptr: *const c_char) -> Vec<u8> {
    if ptr.is_null() {
        return Vec::new();
    }
    // SAFETY: non-null, so NUL-terminated per the contract.
    unsafe { CStr::from_ptr(ptr) }.to_bytes().to_vec()
}

/// The bytes of a buffer of `len` bytes.
///
/// # Safety
/// `ptr` points at `len` readable bytes, or is null.
unsafe fn bytes_of_len(ptr: *const c_char, len: usize) -> Vec<u8> {
    if ptr.is_null() {
        return Vec::new();
    }
    // SAFETY: non-null, so `len` readable bytes per the contract.
    unsafe { std::slice::from_raw_parts(ptr.cast::<u8>(), len) }.to_vec()
}

/// The pointers of a `malloc`ed array, which is freed.
///
/// # Safety
/// `items` is a `malloc`ed array of `count` pointers, or null.
unsafe fn take_array<T>(items: *mut *mut T, count: usize) -> Vec<*mut T> {
    if items.is_null() {
        return Vec::new();
    }
    // SAFETY: non-null, so `count` pointers per the contract, and ours to
    // free once copied out.
    unsafe {
        let copied = std::slice::from_raw_parts(items, count).to_vec();
        free(items as *mut _);
        copied
    }
}

/// A `malloc`ed, NUL-terminated copy, for C to `free`.
fn c_copy(bytes: &[u8]) -> *mut c_char {
    // SAFETY: the copy and the NUL fit the `len + 1` bytes `malloc` returned,
    // and a NULL return (allocation failed) is passed on as such.
    unsafe {
        let ptr = malloc(bytes.len() + 1) as *mut u8;
        if ptr.is_null() {
            return ptr.cast();
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr, bytes.len());
        *ptr.add(bytes.len()) = 0;
        ptr.cast()
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

/// Ok while the round has had every input the parser asked for, an error once
/// it lacks one: entry.rs answers such a round with what it lacks, whatever
/// else came of it, and the analysis of a parsed tree costs more than the
/// parse under the interpreter Bazel runs the module with.
pub fn complete_round() -> Result<(), String> {
    if with(|session| session.host.pending()) {
        return Err("the round lacks an input the parser asked for".to_string());
    }
    Ok(())
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

// The host functions of shim.h, which shim.c calls. Their arguments are
// strings and out-parameters of the parser's, read and written only during
// the call.

/// # Safety
/// `path` is a NUL-terminated string or null; `len` and `status` are
/// writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kconfig_rust_read(
    path: *const c_char,
    len: *mut usize,
    status: *mut c_int,
) -> *mut c_char {
    // SAFETY: per the contract.
    let path = unsafe { bytes_of(path) };
    let (bytes, code) = with_current((Vec::new(), 1), |session| match session.host.read(&path) {
        Ok(bytes) => (bytes, 0),
        Err(ReadError::NotFound) => (Vec::new(), 1),
        Err(ReadError::IsDirectory) => (Vec::new(), 2),
    });
    // SAFETY: per the contract.
    unsafe {
        *status = code;
        *len = bytes.len();
    }
    c_copy(&bytes)
}

/// # Safety
/// `path` is a NUL-terminated string or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kconfig_rust_isdir(path: *const c_char) -> c_int {
    // SAFETY: per the contract.
    let path = unsafe { bytes_of(path) };
    with_current(false, |session| session.host.isdir(&path)) as c_int
}

/// # Safety
/// `path` is a NUL-terminated string or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kconfig_rust_exists(path: *const c_char) -> c_int {
    // SAFETY: per the contract.
    let path = unsafe { bytes_of(path) };
    with_current(false, |session| session.host.exists(&path)) as c_int
}

/// # Safety
/// `name` is a NUL-terminated string or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kconfig_rust_getenv(name: *const c_char) -> *mut c_char {
    // SAFETY: per the contract.
    let name = unsafe { bytes_of(name) };
    match with_current(None, |session| session.getenv(&name)) {
        Some(value) => c_copy(&value),
        None => std::ptr::null_mut(),
    }
}

/// # Safety
/// `command` is a NUL-terminated string or null; `len` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kconfig_rust_shell(
    command: *const c_char,
    len: *mut usize,
) -> *mut c_char {
    // SAFETY: per the contract.
    let command = unsafe { bytes_of(command) };
    let output = with_current(b"n".to_vec(), |session| session.shell(&command));
    // SAFETY: per the contract.
    unsafe {
        *len = output.len();
    }
    c_copy(&output)
}
