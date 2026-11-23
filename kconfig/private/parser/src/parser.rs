//! The parsed tree, the surface of the kernel's parser the generators read
//! (see shim.c): the symbols, their values and where they are defined.

use std::collections::BTreeSet;
use std::ffi::CString;

use crate::ffi;

/// The type constants of shim.h.
pub const UNKNOWN: i32 = 0;
pub const BOOL: i32 = 1;
pub const TRISTATE: i32 = 2;
pub const STRING: i32 = 3;
pub const INT: i32 = 4;
pub const HEX: i32 = 5;

pub struct Kconfig {
    /// What `load_config` has loaded so far.
    config_text: Option<Vec<u8>>,
}

#[derive(Clone, Copy)]
pub struct Symbol {
    inner: ffi::Symbol,
}

/// Where a symbol is defined.
pub struct Node {
    pub filename: Vec<u8>,
    pub linenr: i32,
}

/// The value a `.config` gave a symbol: 0, 1 or 2 for a bool or tristate,
/// the text otherwise.
#[derive(Debug, PartialEq)]
pub enum UserValue {
    Tri(i32),
    Str(Vec<u8>),
}

fn c_string(bytes: &[u8]) -> Result<CString, String> {
    CString::new(bytes).map_err(|_| "a path contains a NUL byte".to_string())
}

impl Kconfig {
    /// The kernel release of the parser selected for the call, `6.12`, as
    /// `kconfig_version` names it.
    pub fn kernel_version() -> Vec<u8> {
        ffi::shim().version()
    }

    /// Parse the tree rooted at `filename`, through the session's host.
    pub fn parse(filename: &[u8]) -> Result<Kconfig, String> {
        let name = c_string(filename)?;
        match ffi::shim().parse(&name) {
            0 => Ok(Kconfig { config_text: None }),
            1 => Err(format!(
                "[Errno 2] No such file or directory: '{}'",
                String::from_utf8_lossy(filename)
            )),
            2 => Err(String::from_utf8_lossy(&Self::diagnostics()).into_owned()),
            _ => Err(
                "the kernel's parser keeps its state in globals and parses one Kconfig per process"
                    .to_string(),
            ),
        }
    }

    /// What the parser printed to stderr.
    pub fn diagnostics() -> Vec<u8> {
        ffi::shim().diagnostics()
    }

    /// The Kconfig files read, in order.
    pub fn kconfig_filenames(&self) -> Vec<Vec<u8>> {
        ffi::shim().filenames()
    }

    /// Every named symbol once, in the order the menu tree defines them.
    pub fn unique_defined_syms(&self) -> Vec<Symbol> {
        let mut seen = BTreeSet::new();
        ffi::shim()
            .menu_symbols()
            .into_iter()
            .filter(|symbol| seen.insert(symbol.id()))
            .map(|inner| Symbol { inner })
            .collect()
    }

    /// `load_config(text, replace)`: read a `.config`, which resets every
    /// user value first; with `replace` false the file is read after what was
    /// loaded before, so that its values override and the rest stay.
    pub fn load_config(&mut self, text: Vec<u8>, replace: bool) -> Result<(), String> {
        let text = match (&self.config_text, replace) {
            (Some(previous), false) => {
                let mut merged = previous.clone();
                merged.push(b'\n');
                merged.extend_from_slice(&text);
                merged
            }
            _ => text,
        };
        let loaded = ffi::shim().load_config(&text);
        self.config_text = Some(text);
        if !loaded {
            return Err("the parser could not read the configuration".to_string());
        }
        Ok(())
    }

    /// The `.config` the kernel writes, after `header`.
    pub fn config_contents(&self, header: &[u8]) -> Result<Vec<u8>, String> {
        let contents = ffi::shim()
            .config_contents()
            .ok_or_else(|| "the parser could not write the configuration".to_string())?;
        let mut text = header.to_vec();
        text.extend(contents);
        Ok(text)
    }
}

impl Symbol {
    /// The name, without `CONFIG_`.
    pub fn name(&self) -> Vec<u8> {
        self.inner.name()
    }

    /// The type as declared: one of the constants above.
    pub fn orig_type(&self) -> i32 {
        self.inner.type_()
    }

    /// The value as a string, calculated.
    pub fn str_value(&self) -> Vec<u8> {
        self.inner.str_value()
    }

    /// The value a `.config` gave, or None.
    pub fn user_value(&self) -> Option<UserValue> {
        if !self.inner.has_user_value() {
            return None;
        }
        if matches!(self.orig_type(), BOOL | TRISTATE) {
            return Some(UserValue::Tri(self.inner.user_tri()));
        }
        Some(UserValue::Str(self.inner.user_str()))
    }

    /// Whether a `.config` can set the symbol: it has a prompt whose
    /// condition holds.
    pub fn visible(&self) -> bool {
        self.inner.visible()
    }

    /// Whether the Kconfig tools write the symbol to `.config` and
    /// `autoconf.h`: it is visible or a default applies. One they do not
    /// write has no value.
    pub fn written(&self) -> bool {
        self.inner.written()
    }

    /// The menu nodes defining the symbol.
    pub fn nodes(&self) -> Vec<Node> {
        self.inner
            .nodes()
            .into_iter()
            .map(|menu| Node {
                filename: menu.filename(),
                linenr: menu.lineno(),
            })
            .collect()
    }
}
