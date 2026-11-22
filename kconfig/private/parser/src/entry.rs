//! The entry point: one request in, one response out, as entry.py answered
//! them (see the module documentation of lib.rs for the protocol).

use serde_bytes::ByteBuf;

use crate::ffi;
use crate::host::{Host, Session};
use crate::json::Value;
use crate::parser::Kconfig;
use crate::request::Request;
use crate::{overrides, paths, repository};

fn error(message: impl Into<Vec<u8>>) -> Value {
    Value::Object(vec![
        (b"status".to_vec(), Value::str("error")),
        (b"message".to_vec(), Value::Str(message.into())),
    ])
}

fn ok(files: Vec<(&str, Vec<u8>)>, manifest: Value) -> Value {
    Value::Object(vec![
        (b"status".to_vec(), Value::str("ok")),
        (
            b"files".to_vec(),
            Value::Object(
                files
                    .into_iter()
                    .map(|(name, content)| (name.as_bytes().to_vec(), Value::Str(content)))
                    .collect(),
            ),
        ),
        (b"manifest".to_vec(), manifest),
    ])
}

fn bytes(field: &Option<ByteBuf>) -> Option<&[u8]> {
    field.as_ref().map(|b| b.as_slice())
}

/// A field the command needs.
fn required<'a>(field: &'a Option<ByteBuf>, name: &str) -> Result<&'a [u8], String> {
    bytes(field).ok_or_else(|| format!("the request has no '{}'", name))
}

/// A field that may be missing, null or empty, which all mean none.
fn optional(field: &Option<ByteBuf>) -> Option<&[u8]> {
    bytes(field).filter(|s| !s.is_empty())
}

/// Run the generator of `request.command`.
fn generate(request: &Request) -> Result<Value, String> {
    let command = bytes(&request.command).unwrap_or_default();
    let srctree = paths::internal(required(&request.srctree, "srctree")?);
    let kconfig = paths::internal(required(&request.kconfig, "kconfig")?);
    let settings_labels = request.settings_labels();
    // The parser of the kernel release Starlark resolved `kconfig_version`
    // to; the newest linked in when the request names none.
    ffi::select(optional(&request.parser_version))?;
    let parser_version = Kconfig::kernel_version();
    match command {
        b"repository" => {
            let defaults = optional(&request.defaults).map(paths::internal);
            let config_ws_path = optional(&request.config_ws_path);
            let kconfig_env = request.kconfig_env();
            let outputs = repository::generate(&repository::Request {
                kconfig: &kconfig,
                srctree: &srctree,
                repo_name: required(&request.repo_name, "repo_name")?,
                defaults: defaults.as_deref(),
                config_ws_path,
                settings_labels: &settings_labels,
                settings_options: request.settings_options.as_ref(),
                env: &kconfig_env,
                kconfig_version: optional(&request.kconfig_version).unwrap_or(&parser_version),
                parser_version: &parser_version,
            })?;
            Ok(ok(
                vec![
                    ("BUILD.bazel", outputs.build),
                    ("kconfig.manifest.json", outputs.manifest_json),
                    ("config.h.in", outputs.config_h_in),
                    ("rendered.config", outputs.rendered_config),
                    ("settings.bzl", outputs.settings_bzl),
                    ("settings/BUILD.bazel", outputs.settings_build),
                ],
                outputs.manifest,
            ))
        }
        b"overrides" => {
            let base_config = optional(&request.base_config).map(paths::internal);
            let outputs = overrides::generate(&overrides::Request {
                kconfig: &kconfig,
                srctree: &srctree,
                config: &paths::internal(required(&request.config, "config")?),
                kconfig_repo: required(&request.kconfig_repo, "kconfig_repo")?,
                config_ws_path: required(&request.config_ws_path, "config_ws_path")?,
                base_config: base_config.as_deref(),
                settings_labels: &settings_labels,
            })?;
            Ok(ok(
                vec![
                    ("defs.bzl", outputs.defs),
                    ("BUILD.bazel", outputs.build),
                    ("rendered.config", outputs.rendered_config),
                ],
                Value::Null,
            ))
        }
        other => Err(format!(
            "unknown command '{}'",
            String::from_utf8_lossy(other)
        )),
    }
}

/// Answer one request: the generated files, what is missing, or an error.
pub fn handle(request: &Request) -> Value {
    let srctree = match required(&request.srctree, "srctree") {
        Ok(srctree) => paths::internal(srctree),
        Err(message) => return error(message),
    };
    ffi::install(Session {
        host: Host::new(request),
        srctree,
    });
    // The kernel's parser reads these late, at `conf_write`, which would cost
    // a round of their own; asked for now, they come with the first.
    ffi::with(|session| {
        session.getenv(b"CONFIG_");
        session.getenv(b"KCONFIG_CONFIG_HEADER");
    });
    let response = match generate(request) {
        Ok(response) => response,
        Err(message) => error(message),
    };
    let mut session = ffi::take().expect("the session was installed above");

    // A round that lacked something is discarded, whatever came of it.
    if session.host.pending() {
        return session.host.needs();
    }
    response
}

/// The exported function: a JSON request in, a JSON response out.
pub fn run(payload: &[u8]) -> Vec<u8> {
    let response = match Request::parse(payload) {
        Ok(request) => handle(&request),
        Err(message) => error(message),
    };
    response.dump()
}
