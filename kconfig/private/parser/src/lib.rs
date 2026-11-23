//! The WebAssembly backend of rules_kconfig: the kernel's Kconfig parser and
//! the generators of a kconfig repository, run by Bazel's
//! `repository_ctx.execute_wasm`.
//!
//! Nothing inside the module can touch the filesystem, read the environment,
//! run a command or read the clock; Starlark does all of that. So a
//! repository is generated in rounds: `run` receives everything Starlark has
//! read so far, and either produces the repository's files, or answers with
//! what it is missing. Starlark reads or runs that, and calls again with the
//! larger request, until the generation completes. Every round starts the
//! generation over, so Starlark reads the source tree ahead (the listing of
//! every directory and every `Kconfig*` file) and the variables the parser
//! reads on its own; a request that carries them usually completes in its
//! first round, with a second for `$(shell,...)` commands. A path whose
//! directory is listed but which is not in the listing is known to be
//! missing without a round. The environment is looked up name by name, like
//! files: a variable is unknown until Starlark answers for it, with null
//! when it is unset. Only `CONFIG_` and `KCONFIG_CONFIG_HEADER` are read
//! unprompted; a Kconfig may name any other through `$(NAME)` or
//! `option env=`.
//!
//! The request and the response are JSON, exchanged as bytes: the UTF-8 of
//! the Starlark strings, which for a file's content are the file's own
//! bytes, since Bazel reads files byte for byte. A byte that is not UTF-8
//! passes through unchanged, in and out.
//!
//! Request:
//!
//! ```text
//! {
//!   "command": "repository" | "overrides",
//!   "env": {name: value | null},          # repository_ctx.getenv, null when unset
//!   "srctree": "<absolute path>",
//!   "kconfig": "<absolute path of the root Kconfig>",
//!   "files": {path: {"exists": bool, "is_dir": bool, "content": str | null}},
//!   "dirs": {path: [[name, is_dir], ...] | null},
//!   "shell": {command: {"stdout": str, "stderr": str, "return_code": int}},
//!   "kconfig_version": str,               # the kernel release the consumer named
//!   "parser_version": str,                # the release whose parser to use
//!   # "repository":
//!   "repo_name": str, "defaults": path | null, "config_ws_path": str | null,
//!   "settings_labels": {name: label}, "settings_options": {name: [value]},
//!   # "overrides":
//!   "config": path, "base_config": path | null, "kconfig_repo": str,
//!   "config_ws_path": str, "settings_labels": {name: label}
//! }
//! ```
//!
//! Response:
//!
//! ```text
//! {"status": "need", "files": [path], "shell": [command], "env": [name]}
//! {"status": "ok", "files": {name: content}, "manifest": {...}}
//! {"status": "error", "message": str}
//! ```
//!
//! The parsers are the Linux kernel's (`scripts/kconfig`, see
//! `kconfig/private/parser/kernel`) of the releases
//! `//kconfig/private:versions.bzl` lists, each behind its own copy of
//! shim.c and all linked into the one program (see ffi.rs).

// The binding to the parser is the crate's unsafe code, confined to ffi.rs,
// which allows it back for itself and explains each block.
#![deny(unsafe_code)]
#![deny(clippy::undocumented_unsafe_blocks)]

pub mod entry;
pub mod ffi;
pub mod host;
pub mod json;
pub mod overrides;
pub mod parser;
pub mod paths;
pub mod render;
pub mod repository;
pub mod request;
pub mod settings;
pub mod text;
