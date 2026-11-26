//! The request, as Starlark sends it (see lib.rs for the shape).
//!
//! Strings are byte strings: a file's content is the file's own bytes, which
//! need not be UTF-8, and so may a path. Maps keep their order, as Python
//! dicts did, which the manifest's `settings_labels` shows. The maps hash
//! with fixed keys: the module has no source of randomness, and asks its host
//! for none.

use std::hash::{BuildHasherDefault, DefaultHasher};

use indexmap::IndexMap;
use serde::Deserialize;
use serde_bytes::ByteBuf;

/// An insertion-ordered map with a fixed hasher.
pub type Map<K, V> = IndexMap<K, V, BuildHasherDefault<DefaultHasher>>;

#[derive(Debug, Deserialize)]
pub struct FileInfo {
    #[serde(default)]
    pub exists: bool,
    #[serde(default)]
    pub is_dir: bool,
    #[serde(default)]
    pub content: Option<ByteBuf>,
}

#[derive(Debug, Deserialize)]
pub struct ShellResult {
    #[serde(default)]
    pub stdout: ByteBuf,
}

#[derive(Debug, Deserialize)]
pub struct Request {
    #[serde(default)]
    pub command: Option<ByteBuf>,
    #[serde(default)]
    pub srctree: Option<ByteBuf>,
    #[serde(default)]
    pub kconfig: Option<ByteBuf>,
    /// `repository_ctx.getenv`, null when unset.
    #[serde(default)]
    pub env: Map<ByteBuf, Option<ByteBuf>>,
    #[serde(default)]
    pub files: Map<ByteBuf, Option<FileInfo>>,
    /// A directory's entries, `[name, is_dir]`; null when there is no such
    /// directory.
    #[serde(default)]
    pub dirs: Map<ByteBuf, Option<Vec<(ByteBuf, bool)>>>,
    #[serde(default)]
    pub shell: Map<ByteBuf, Option<ShellResult>>,

    /// The kernel release the consumer named (`kconfig_version`), recorded
    /// in the manifest; the parser's own when absent.
    #[serde(default)]
    pub kconfig_version: Option<ByteBuf>,
    /// The release of the parser Starlark chose for it, one of the parsers
    /// linked in; the newest when absent.
    #[serde(default)]
    pub parser_version: Option<ByteBuf>,

    // `repository`
    #[serde(default)]
    pub repo_name: Option<ByteBuf>,
    #[serde(default)]
    pub defaults: Option<ByteBuf>,
    #[serde(default)]
    pub config_ws_path: Option<ByteBuf>,
    /// `CONFIG_*` names mapped to the labels of user-provided build settings.
    #[serde(default)]
    pub settings_labels: Option<Map<ByteBuf, ByteBuf>>,
    /// `CONFIG_*` names mapped to the values to generate `config_setting`s for.
    #[serde(default)]
    pub settings_options: Option<Map<String, Vec<String>>>,
    /// Whether the symbols the configuration makes invisible are written to
    /// `rendered.config` and defined in `config.h`, as BusyBox's kconfig
    /// does; the Linux tools leave them out.
    #[serde(default)]
    pub write_invisible: bool,
    /// The variables the repository rule's `env` attribute gives the tree,
    /// recorded in the manifest for the overrides layered on the repository.
    /// Starlark has merged them into `env` already.
    #[serde(default)]
    pub kconfig_env: Option<Map<ByteBuf, ByteBuf>>,

    // `overrides`
    #[serde(default)]
    pub config: Option<ByteBuf>,
    #[serde(default)]
    pub base_config: Option<ByteBuf>,
    #[serde(default)]
    pub kconfig_repo: Option<ByteBuf>,
}

impl Request {
    pub fn parse(payload: &[u8]) -> Result<Request, String> {
        serde_json::from_slice(payload).map_err(|e| format!("invalid request: {}", e))
    }

    /// The labels, in the request's order; an absent or null map is empty.
    pub fn settings_labels(&self) -> Vec<(Vec<u8>, Vec<u8>)> {
        Self::pairs(&self.settings_labels)
    }

    pub fn kconfig_env(&self) -> Vec<(Vec<u8>, Vec<u8>)> {
        Self::pairs(&self.kconfig_env)
    }

    fn pairs(map: &Option<Map<ByteBuf, ByteBuf>>) -> Vec<(Vec<u8>, Vec<u8>)> {
        map.as_ref()
            .map(|map| map.iter().map(|(k, v)| (k.to_vec(), v.to_vec())).collect())
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_bytes_and_order() {
        let payload = b"{\"command\": \"repository\", \"srctree\": \"/t\", \"kconfig\": \"/t/Kconfig\",
            \"files\": {\"/t/caf\xe9\": {\"exists\": true, \"is_dir\": false, \"content\": \"caf\xe9\\n\"}},
            \"env\": {\"B\": null, \"A\": \"1\"}, \"settings_labels\": {\"Z\": \"@//:z\", \"A\": \"@//:a\"}}";
        let request = Request::parse(payload).unwrap();
        let (path, info) = request.files.first().unwrap();
        assert_eq!(path.as_ref(), b"/t/caf\xe9");
        assert_eq!(
            info.as_ref().unwrap().content.as_ref().unwrap().as_ref(),
            b"caf\xe9\n"
        );
        assert_eq!(
            request.env.keys().map(|k| k.to_vec()).collect::<Vec<_>>(),
            [b"B".to_vec(), b"A".to_vec()]
        );
        assert_eq!(
            request
                .settings_labels()
                .iter()
                .map(|(k, _)| k.clone())
                .collect::<Vec<_>>(),
            [b"Z".to_vec(), b"A".to_vec()]
        );
        assert!(request.repo_name.is_none());
    }

    #[test]
    fn rejects_malformed_payloads() {
        assert!(Request::parse(b"not json").is_err());
        assert!(Request::parse(b"{\"files\": 1}").is_err());
    }
}
