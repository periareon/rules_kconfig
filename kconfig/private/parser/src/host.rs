//! What Starlark has provided so far, and what a round found missing.
//!
//! The module cannot touch the filesystem, the environment or a shell, so a
//! request carries what Starlark has read, and the lookups here answer from
//! it. A lookup of something the request does not have hands back a
//! placeholder and records the request, so that one round discovers as much
//! as it can; a round that recorded anything is discarded, and run again
//! once Starlark has answered. A listed directory answers for the paths
//! under it: a name that is not in the listing is missing, and is not asked
//! for.
//!
//! Paths are kept in the module's form (see `paths::internal`) and handed
//! back to Starlark in the host's.

use std::collections::{BTreeMap, BTreeSet};

use crate::json::Value;
use crate::request::Request;
use crate::{paths, text};

#[derive(Clone, Debug)]
pub struct FileInfo {
    pub exists: bool,
    pub is_dir: bool,
    pub content: Option<Vec<u8>>,
}

#[derive(Clone, Debug)]
pub struct ShellResult {
    pub stdout: Vec<u8>,
}

/// Why a file could not be read, with the message of the Python error.
#[derive(Debug)]
pub enum ReadError {
    NotFound,
    IsDirectory,
}

impl ReadError {
    pub fn message(&self, path: &[u8]) -> String {
        let path = String::from_utf8_lossy(path);
        match self {
            ReadError::NotFound => format!("[Errno 2] No such file or directory: '{}'", path),
            ReadError::IsDirectory => format!("[Errno 21] Is a directory: '{}'", path),
        }
    }
}

/// What a round asked for and did not have, by kind, in the order asked.
#[derive(Default)]
struct Pending {
    files: Requests,
    shell: Requests,
    env: Requests,
}

#[derive(Default)]
struct Requests {
    items: Vec<Vec<u8>>,
    seen: BTreeSet<Vec<u8>>,
}

impl Requests {
    fn add(&mut self, item: &[u8]) {
        if self.seen.insert(item.to_vec()) {
            self.items.push(item.to_vec());
        }
    }

    fn is_empty(&self) -> bool {
        self.items.is_empty()
    }
}

/// A directory's entries: each name, and whether it is a directory.
type Listing = Vec<(Vec<u8>, bool)>;

pub struct Host {
    files: BTreeMap<Vec<u8>, FileInfo>,
    dirs: BTreeMap<Vec<u8>, Option<Listing>>,
    shell_results: BTreeMap<Vec<u8>, Option<ShellResult>>,
    /// The variables Starlark has looked up; None is unset.
    env: BTreeMap<Vec<u8>, Option<Vec<u8>>>,
    pending: Pending,
}

impl Host {
    pub fn new(request: &Request) -> Host {
        let files = request
            .files
            .iter()
            .filter_map(|(path, info)| {
                let info = info.as_ref()?;
                Some((
                    paths::internal(path),
                    FileInfo {
                        exists: info.exists,
                        is_dir: info.is_dir,
                        content: info.content.as_ref().map(|c| c.to_vec()),
                    },
                ))
            })
            .collect();
        let dirs = request
            .dirs
            .iter()
            .map(|(path, entries)| {
                let entries = entries.as_ref().map(|entries| {
                    entries
                        .iter()
                        .map(|(name, is_dir)| (name.to_vec(), *is_dir))
                        .collect()
                });
                (paths::internal(path), entries)
            })
            .collect();
        let shell_results = request
            .shell
            .iter()
            .map(|(command, result)| {
                let result = result.as_ref().map(|result| ShellResult {
                    stdout: result.stdout.to_vec(),
                });
                (command.to_vec(), result)
            })
            .collect();
        let env = request
            .env
            .iter()
            .map(|(name, value)| (name.to_vec(), value.as_ref().map(|v| v.to_vec())))
            .collect();
        Host {
            files,
            dirs,
            shell_results,
            env,
            pending: Pending::default(),
        }
    }

    // -- Lookups -------------------------------------------------------------

    /// The file's info, or None while unknown.
    pub fn stat(&mut self, path: &[u8]) -> Option<&FileInfo> {
        if !self.files.contains_key(path) {
            match self.listing_stat(path) {
                Some(info) => {
                    self.files.insert(path.to_vec(), info);
                }
                None => {
                    self.pending.files.add(path);
                    return None;
                }
            }
        }
        self.files.get(path)
    }

    /// What the listing of a path's directory says of it: missing, or a
    /// directory. None when the listing is unknown, or names a file, whose
    /// content still has to be read.
    fn listing_stat(&self, path: &[u8]) -> Option<FileInfo> {
        let (dirname, basename) = paths::split(path);
        if basename.is_empty() {
            return None;
        }
        let entries = self.dirs.get(dirname)?;
        if let Some(entries) = entries {
            for (name, is_dir) in entries {
                if name == basename {
                    if *is_dir {
                        return Some(FileInfo {
                            exists: true,
                            is_dir: true,
                            content: None,
                        });
                    }
                    return None;
                }
            }
        }
        Some(FileInfo {
            exists: false,
            is_dir: false,
            content: None,
        })
    }

    /// Whether the variable is known, and its value; None is unset.
    pub fn getenv(&mut self, name: &[u8]) -> (bool, Option<Vec<u8>>) {
        if let Some(value) = self.env.get(name) {
            return (true, value.clone());
        }
        self.pending.env.add(name);
        (false, None)
    }

    /// Whether the file exists; false while unknown.
    pub fn exists(&mut self, path: &[u8]) -> bool {
        self.stat(path).is_some_and(|info| info.exists)
    }

    /// Whether the path is a directory; false while unknown.
    pub fn isdir(&mut self, path: &[u8]) -> bool {
        self.stat(path)
            .is_some_and(|info| info.exists && info.is_dir)
    }

    /// The bytes of a file; an empty file while unknown.
    pub fn read(&mut self, path: &[u8]) -> Result<Vec<u8>, ReadError> {
        match self.stat(path) {
            None => Ok(Vec::new()),
            Some(info) if !info.exists => Err(ReadError::NotFound),
            Some(info) if info.is_dir => Err(ReadError::IsDirectory),
            Some(info) => Ok(info.content.clone().unwrap_or_default()),
        }
    }

    /// The output of a `$(shell,...)` command as the parser reads it; None
    /// while unknown.
    pub fn shell(&mut self, command: &[u8]) -> Option<Vec<u8>> {
        if !self.shell_results.contains_key(command) {
            self.pending.shell.add(command);
            return None;
        }
        let result = self.shell_results.get(command)?.as_ref()?;
        let lines = text::splitlines(&result.stdout);
        let joined = lines.join(&b"\n"[..]);
        let stripped = text::rstrip_newlines(&joined);
        Some(
            stripped
                .iter()
                .map(|&b| if b == b'\n' { b' ' } else { b })
                .collect(),
        )
    }

    /// Whether this round asked for anything it did not have.
    pub fn pending(&self) -> bool {
        !self.pending.files.is_empty()
            || !self.pending.shell.is_empty()
            || !self.pending.env.is_empty()
    }

    /// The `need` response listing what the next round must provide.
    pub fn needs(&self) -> Value {
        let as_paths = |requests: &Requests| {
            Value::Array(
                requests
                    .items
                    .iter()
                    .map(|item| Value::Str(paths::host(item)))
                    .collect(),
            )
        };
        let as_strings = |requests: &Requests| {
            Value::Array(
                requests
                    .items
                    .iter()
                    .map(|item| Value::Str(item.clone()))
                    .collect(),
            )
        };
        Value::Object(vec![
            (b"status".to_vec(), Value::str("need")),
            (b"files".to_vec(), as_paths(&self.pending.files)),
            (b"shell".to_vec(), as_strings(&self.pending.shell)),
            (b"env".to_vec(), as_strings(&self.pending.env)),
        ])
    }
}

/// The host's environment as the parser looks it up: `srctree` is fixed by
/// the request; any other name goes through the host, which asks Starlark
/// for it the first time. An unset or unknown variable is absent.
pub struct Session {
    pub host: Host,
    pub srctree: Vec<u8>,
}

impl Session {
    pub fn getenv(&mut self, name: &[u8]) -> Option<Vec<u8>> {
        if name == b"srctree" {
            return Some(self.srctree.clone());
        }
        self.host.getenv(name).1
    }

    /// `$(shell,...)` as the parser reads it: the host's answer, or "n" where
    /// there is none yet or it is empty, which tokenizes validly in a bool or
    /// tristate default; a tainted symbol gets a fixed default regardless.
    pub fn shell(&mut self, command: &[u8]) -> Vec<u8> {
        match self.host.shell(command) {
            Some(output) if !output.is_empty() => output,
            _ => b"n".to_vec(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn answers_from_listings_and_records_the_rest() {
        let request = Request::parse(
            br#"{"files": {"/t/Kconfig": {"exists": true, "is_dir": false, "content": "x"}},
                "dirs": {"/t": [["Kconfig", false], ["sub", true]], "/t/sub": []},
                "env": {"A": "1", "B": null}, "shell": {}}"#,
        )
        .unwrap();
        let mut host = Host::new(&request);
        assert_eq!(host.read(b"/t/Kconfig").unwrap(), b"x");
        assert!(host.isdir(b"/t/sub"));
        assert!(matches!(host.read(b"/t/missing"), Err(ReadError::NotFound)));
        assert!(matches!(
            host.read(b"/t/sub/Kconfig"),
            Err(ReadError::NotFound)
        ));
        assert!(!host.pending());
        assert_eq!(host.read(b"/elsewhere/Kconfig").unwrap(), b"");
        assert_eq!(host.getenv(b"A"), (true, Some(b"1".to_vec())));
        assert_eq!(host.getenv(b"B"), (true, None));
        assert_eq!(host.getenv(b"C"), (false, None));
        assert!(host.pending());
        let needs = host.needs();
        assert_eq!(
            needs.get("files").unwrap().as_array().unwrap(),
            &[Value::str("/elsewhere/Kconfig")]
        );
        assert_eq!(
            needs.get("env").unwrap().as_array().unwrap(),
            &[Value::str("C")]
        );
    }

    #[test]
    fn shell_output_is_one_line() {
        let request = Request::parse(
            br#"{"shell": {"echo": {"stdout": "a\nb\n\n", "stderr": "", "return_code": 0}}}"#,
        )
        .unwrap();
        let mut host = Host::new(&request);
        assert_eq!(host.shell(b"echo").unwrap(), b"a b");
        assert_eq!(host.shell(b"other"), None);
    }
}
