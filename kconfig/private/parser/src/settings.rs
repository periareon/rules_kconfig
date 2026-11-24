//! From parsed symbols to build settings: what kconfig_parser.py did.
//!
//! A symbol whose definition names `$(shell,...)`, directly or through a
//! preprocessor variable, would take a host-dependent default. Where a
//! `.config` can set it (it is visible) it gets the falsey default of its
//! type instead, and with a defaults file it must be set there. Where no
//! `.config` can set it, as it has no prompt or its prompt's condition does
//! not hold (the kernel's `CC_IS_GCC` and the compiler probes behind it), it
//! has the value the Kconfig tools calculate for it, as `rendered.config`
//! does; `settings_labels` replaces it with a build-time value.

use std::collections::{BTreeMap, BTreeSet};

use crate::parser::{self, Kconfig, Node};
use crate::{paths, text};

/// A default, as the Python backend held it: a `bool`, an `int` or a `str`.
#[derive(Clone, Debug, PartialEq)]
pub enum Default {
    Bool(bool),
    /// A decimal integer, canonical.
    Int(String),
    Str(Vec<u8>),
}

/// A Kconfig symbol as a Bazel build setting.
#[derive(Clone, Debug)]
pub struct Setting {
    /// The symbol's name, without `CONFIG_`.
    pub name: Vec<u8>,
    /// `bool_flag`, `tristate_flag`, `int_flag` or `string_flag`.
    pub rule: &'static str,
    pub default: Default,
    /// `bool`, `tristate`, `int`, `hex` or `string`.
    pub kconfig_type: &'static str,
    /// Whether the configuration gives the symbol a value: the Kconfig tools
    /// write it to `.config` and `autoconf.h`. A build setting needs a value
    /// either way, so one they do not write has what the parser calculates,
    /// which is only the seed of its type (`0` for an `int`).
    pub written: bool,
}

impl Setting {
    pub fn config_name(&self) -> Vec<u8> {
        let mut name = b"CONFIG_".to_vec();
        name.extend_from_slice(&self.name);
        name
    }
}

fn rule_of(orig_type: i32) -> Option<&'static str> {
    match orig_type {
        parser::BOOL => Some("bool_flag"),
        parser::TRISTATE => Some("tristate_flag"),
        parser::INT => Some("int_flag"),
        parser::HEX | parser::STRING => Some("string_flag"),
        _ => None,
    }
}

fn kconfig_type_of(orig_type: i32) -> &'static str {
    match orig_type {
        parser::BOOL => "bool",
        parser::TRISTATE => "tristate",
        parser::INT => "int",
        parser::HEX => "hex",
        _ => "string",
    }
}

fn falsey_default(rule: &str) -> Default {
    match rule {
        "bool_flag" => Default::Bool(false),
        "tristate_flag" => Default::Str(b"n".to_vec()),
        "int_flag" => Default::Int("0".to_string()),
        _ => Default::Str(Vec::new()),
    }
}

/// A symbol's resolved value as the Python backend converted it.
fn python_default(str_value: &[u8], rule: &str) -> Default {
    match rule {
        "bool_flag" => Default::Bool(str_value == b"y"),
        "int_flag" => Default::Int(text::python_int(str_value).unwrap_or_else(|| "0".to_string())),
        _ => Default::Str(str_value.to_vec()),
    }
}

const BLOCK_STARTERS: &[&[u8]] = &[
    b"config",
    b"menuconfig",
    b"menu",
    b"endmenu",
    b"choice",
    b"endchoice",
    b"comment",
    b"source",
    b"rsource",
    b"osource",
    b"orsource",
    b"if",
    b"endif",
    b"mainmenu",
];

/// What the shell-taint scan needs of one line of a Kconfig source.
#[derive(Debug, Default)]
pub struct Line {
    /// Whether the line starts a block: unindented, with one of
    /// `BLOCK_STARTERS` as its first word. A symbol's definition runs from
    /// its node to the next such line.
    pub starts_block: bool,
    /// The names of the line's `$(NAME` references.
    pub references: Vec<Vec<u8>>,
    /// The preprocessor variable the line assigns, if any, and the names its
    /// value refers to.
    pub assignment: Option<(Vec<u8>, Vec<Vec<u8>>)>,
}

/// Every Kconfig source, scanned, by filename as `kconfig_filenames` lists
/// it. Each line is scanned once, as the file is read: scanning the lines of
/// each symbol's definition when the symbol came up, allocations and all,
/// cost more than parsing the tree under the interpreter Bazel runs the
/// module with.
pub type SourceCache = BTreeMap<Vec<u8>, Vec<Line>>;

/// Scan the text of one source.
pub fn scan_source(content: &[u8]) -> Vec<Line> {
    text::splitlines(content)
        .into_iter()
        .map(scan_line)
        .collect()
}

fn scan_line(line: &[u8]) -> Line {
    let stripped = text::lstrip(line);
    let starts_block = !stripped.is_empty()
        && stripped[0] != b'#'
        && line[0] != b' '
        && line[0] != b'\t'
        && BLOCK_STARTERS.contains(&text::first_word(stripped));
    Line {
        starts_block,
        references: text::macro_references(line),
        assignment: text::variable_assignment(line),
    }
}

/// Read and scan every Kconfig source through `read`, which answers None for
/// a file that cannot be read; such a file is left out, as the Python
/// backend only warned about it.
pub fn read_source_files(
    filenames: &[Vec<u8>],
    srctree: &[u8],
    mut read: impl FnMut(&[u8]) -> Option<Vec<u8>>,
) -> SourceCache {
    let mut cache = BTreeMap::new();
    for filename in filenames {
        let path = if paths::is_absolute(filename) {
            paths::absolute(filename)
        } else {
            paths::absolute(&paths::join(srctree, filename))
        };
        if let Some(content) = read(&path) {
            cache.insert(filename.clone(), scan_source(&content));
        }
    }
    cache
}

/// The preprocessor variables whose value comes from `$(shell,...)`, directly
/// or through another tainted variable, across every source.
pub fn tainted_variables(cache: &SourceCache) -> BTreeSet<Vec<u8>> {
    let mut assigned: BTreeMap<Vec<u8>, BTreeSet<Vec<u8>>> = BTreeMap::new();
    for lines in cache.values() {
        for line in lines {
            if let Some((name, references)) = &line.assignment {
                assigned
                    .entry(name.clone())
                    .or_default()
                    .extend(references.iter().cloned());
            }
        }
    }
    let mut tainted = BTreeSet::new();
    let mut changed = true;
    while changed {
        changed = false;
        for (name, references) in &assigned {
            if !tainted.contains(name)
                && (references.contains(&b"shell"[..])
                    || references.iter().any(|r| tainted.contains(r)))
            {
                tainted.insert(name.clone());
                changed = true;
            }
        }
    }
    tainted
}

/// Whether a definition of the symbol uses `$(shell,...)`, directly or
/// through a tainted variable: the lines from each node to the next block.
pub fn is_shell_tainted(nodes: &[Node], cache: &SourceCache, tainted: &BTreeSet<Vec<u8>>) -> bool {
    for node in nodes {
        let Some(lines) = cache.get(&node.filename) else {
            continue;
        };
        if node.linenr < 1 {
            continue;
        }
        let start = (node.linenr as usize - 1).min(lines.len());
        let mut end = start + 1;
        while end < lines.len() && !lines[end].starts_block {
            end += 1;
        }
        let block = &lines[start..end.min(lines.len())];
        if block.iter().any(|line| {
            line.references
                .iter()
                .any(|r| r == b"shell" || tainted.contains(r))
        }) {
            return true;
        }
    }
    false
}

/// A node's filename as `kconfig_filenames` lists the file: relative to
/// `srctree` where it is under it. The parser names the root by the path it
/// was given.
fn listed_filename(filename: &[u8], srctree: &[u8]) -> Vec<u8> {
    if !srctree.is_empty()
        && filename.starts_with(srctree)
        && filename.get(srctree.len()) == Some(&b'/')
    {
        return filename[srctree.len() + 1..].to_vec();
    }
    filename.to_vec()
}

/// The settings of every symbol with a type the build settings have.
///
/// With `has_defaults`, a `.config` was loaded; a shell-tainted symbol it
/// could set but does not is an error, unless `labeled` has it, which the
/// caller provides a build setting for. `srctree` is the parser's, for the
/// names of files.
pub fn collect_settings(
    kconf: &Kconfig,
    cache: &SourceCache,
    has_defaults: bool,
    labeled: &BTreeSet<Vec<u8>>,
    srctree: &[u8],
) -> Result<Vec<Setting>, String> {
    let tainted = tainted_variables(cache);
    let mut errors = Vec::new();
    let mut settings = Vec::new();
    for sym in kconf.unique_defined_syms() {
        let orig_type = sym.orig_type();
        let Some(rule) = rule_of(orig_type) else {
            continue;
        };
        let nodes: Vec<Node> = sym
            .nodes()
            .into_iter()
            .map(|node| Node {
                filename: listed_filename(&node.filename, srctree),
                linenr: node.linenr,
            })
            .collect();
        let shell_tainted = is_shell_tainted(&nodes, cache, &tainted);
        let name = sym.name();
        let mut config_name = b"CONFIG_".to_vec();
        config_name.extend_from_slice(&name);
        // A tainted symbol a `.config` could set, and none did: its value
        // would be the host's. One no `.config` can set has the calculated
        // value, as the Kconfig tools give it.
        let unset = shell_tainted && sym.visible() && sym.user_value().is_none();
        if unset && has_defaults && !labeled.contains(&config_name) {
            let display = String::from_utf8_lossy(&name);
            errors.push(format!(
                "CONFIG_{display} uses $(shell,...) for its default but is not \
                 explicitly set in the defaults file. Run menuconfig or add \
                 CONFIG_{display}=<value> to your .config file."
            ));
        }
        let default = if unset {
            falsey_default(rule)
        } else {
            python_default(&sym.str_value(), rule)
        };
        settings.push(Setting {
            name,
            rule,
            default,
            kconfig_type: kconfig_type_of(orig_type),
            written: sym.written(),
        });
    }
    if !errors.is_empty() {
        let mut message = "Defaults file is missing required symbols:".to_string();
        for error in errors {
            message.push_str("\n  - ");
            message.push_str(&error);
        }
        return Err(message);
    }
    Ok(settings)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cache(sources: &[(&str, &str)]) -> SourceCache {
        sources
            .iter()
            .map(|(name, content)| (name.as_bytes().to_vec(), scan_source(content.as_bytes())))
            .collect()
    }

    #[test]
    fn scans_lines() {
        let lines = scan_source(
            b"config A\n\tdefault $(B) $(shell,x)\n  config C\n# config D\nE := $(F)\n",
        );
        let starts: Vec<bool> = lines.iter().map(|l| l.starts_block).collect();
        assert_eq!(starts, [true, false, false, false, false]);
        assert_eq!(lines[1].references, [b"B".to_vec(), b"shell".to_vec()]);
        assert_eq!(
            lines[4].assignment,
            Some((b"E".to_vec(), vec![b"F".to_vec()]))
        );
        assert!(lines[0].assignment.is_none());
    }

    #[test]
    fn finds_tainted_variables() {
        let cache = cache(&[("Kconfig", "A := $(shell,x)\nB = $(A)\nC = $(D)\nD := 1\n")]);
        let tainted = tainted_variables(&cache);
        assert_eq!(
            tainted,
            [b"A".to_vec(), b"B".to_vec()].into_iter().collect()
        );
    }

    #[test]
    fn scans_a_definition_to_the_next_block() {
        let cache = cache(&[(
            "Kconfig",
            "config A\n\tint\n\tdefault $(B)\n\nconfig C\n\tint\n\tdefault 1\n\nconfig D\n\tdefault $(shell,y)\n# $(shell,x)\nconfig E\n\tint\n",
        )]);
        let tainted = [b"B".to_vec()].into_iter().collect();
        let node = |linenr| {
            vec![Node {
                filename: b"Kconfig".to_vec(),
                linenr,
            }]
        };
        assert!(is_shell_tainted(&node(1), &cache, &tainted));
        assert!(!is_shell_tainted(&node(5), &cache, &tainted));
        // A comment inside the block counts, as the Python scan had it.
        assert!(is_shell_tainted(&node(9), &cache, &tainted));
        assert!(!is_shell_tainted(&node(12), &cache, &tainted));
        assert!(!is_shell_tainted(
            &[Node {
                filename: b"other".to_vec(),
                linenr: 1
            }],
            &cache,
            &tainted
        ));
    }

    #[test]
    fn converts_defaults() {
        assert_eq!(python_default(b"y", "bool_flag"), Default::Bool(true));
        assert_eq!(
            python_default(b"m", "tristate_flag"),
            Default::Str(b"m".to_vec())
        );
        assert_eq!(
            python_default(b"12", "int_flag"),
            Default::Int("12".to_string())
        );
        assert_eq!(
            python_default(b"", "int_flag"),
            Default::Int("0".to_string())
        );
        assert_eq!(
            python_default(b"0x10", "string_flag"),
            Default::Str(b"0x10".to_vec())
        );
    }

    #[test]
    fn strips_srctree() {
        assert_eq!(
            listed_filename(b"/t/x/Kconfig", b"/t/x"),
            b"Kconfig".to_vec()
        );
        assert_eq!(
            listed_filename(b"/t/xy/Kconfig", b"/t/x"),
            b"/t/xy/Kconfig".to_vec()
        );
        assert_eq!(
            listed_filename(b"sub/Kconfig", b"/t/x"),
            b"sub/Kconfig".to_vec()
        );
    }
}
