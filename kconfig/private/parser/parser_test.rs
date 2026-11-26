//! Tests of the parser, run natively as `kconfig_tool`, at one version.
//!
//! A small host answers the tool's requests from the filesystem the way the
//! Starlark loop does, one process per round, and the files it produces are
//! compared with the golden files under `testdata/<version>/`, which fix the
//! repository the parser of that kernel release generates for each tree. The
//! release is `KCONFIG_VERSION`, which every request names as its
//! `parser_version`, as the repository rules do; the tool `KCONFIG_TOOL` has
//! the parsers of every release. To regenerate the goldens after a deliberate
//! change, run the test with `KCONFIG_PARSER_GOLDENS` naming the absolute
//! path of `testdata` (as a `--test_env`; the sandbox lets the test write
//! there), and review the diff.
//!
//! The trees use what the kernel's parser accepts: `source` with a path, no
//! globs and no `rsource`, which were kconfiglib's own; and `modules` as the
//! release spells it, a property since 6.10 and `option modules` before.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use runfiles::{Runfiles, rlocation};
use serde_json::{Map, Value, json};

/// The variables `new_request` in `parser_backend.bzl` looks up ahead of the
/// first round: the ones the module reads of its own accord.
const PARSER_ENV: [&str; 2] = ["CONFIG_", "KCONFIG_CONFIG_HEADER"];

/// The kernel release the tool under test is built from.
fn version() -> String {
    std::env::var("KCONFIG_VERSION").expect("KCONFIG_VERSION names the release under test")
}

fn version_tuple() -> (u32, u32) {
    let version = version();
    let mut parts = version.split('.').map(|part| part.parse::<u32>().unwrap());
    (parts.next().unwrap(), parts.next().unwrap())
}

/// How the release declares the modules symbol.
fn modules() -> &'static str {
    if version_tuple() >= (6, 10) {
        "modules"
    } else {
        "option modules"
    }
}

fn runfile(variable: &str) -> PathBuf {
    let runfiles = Runfiles::create().expect("the runfiles");
    let rlocationpath = std::env::var(variable).unwrap_or_else(|_| panic!("{variable} is set"));
    let path = rlocation!(runfiles, &rlocationpath)
        .unwrap_or_else(|| panic!("{rlocationpath} is in the runfiles"));
    assert!(path.exists(), "{} exists", path.display());
    path
}

/// The native build of the module.
fn tool() -> PathBuf {
    runfile("KCONFIG_TOOL")
}

/// `testdata/<version>`: the directory of the file `KCONFIG_TESTDATA` names,
/// which is in one of its cases.
fn testdata() -> PathBuf {
    runfile("KCONFIG_TESTDATA")
        .parent()
        .and_then(Path::parent)
        .expect("KCONFIG_TESTDATA is a file of a case")
        .to_path_buf()
}

/// A fresh directory for a test, under Bazel's `TEST_TMPDIR`.
fn tmp_path(name: &str) -> PathBuf {
    let base = std::env::var_os("TEST_TMPDIR")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    let path = base.join("parser_test").join(name);
    if path.exists() {
        std::fs::remove_dir_all(&path).unwrap();
    }
    std::fs::create_dir_all(&path).unwrap();
    path
}

/// One round: the tool's response to a request.
fn run_tool(payload: &[u8]) -> Vec<u8> {
    let mut child = Command::new(tool())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("the tool starts");
    child.stdin.take().unwrap().write_all(payload).unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    output.stdout
}

fn parse(response: &[u8]) -> Value {
    serde_json::from_slice(response)
        .unwrap_or_else(|error| panic!("{error}: {}", String::from_utf8_lossy(response)))
}

fn strings(value: &Value) -> Vec<String> {
    value
        .as_array()
        .unwrap_or_else(|| panic!("{value} is an array"))
        .iter()
        .map(|item| item.as_str().unwrap().to_string())
        .collect()
}

/// Answers the module's requests from the filesystem, like Starlark.
struct Host {
    rounds: usize,
    first_response: Option<Value>,
    /// Every `need` response, in order.
    needs: Vec<Value>,
    /// Variables as the host has them, over the process environment: a
    /// value, or `None` for one unset.
    env: BTreeMap<String, Option<String>>,
}

impl Host {
    fn new() -> Self {
        Host {
            rounds: 0,
            first_response: None,
            needs: Vec::new(),
            env: BTreeMap::new(),
        }
    }

    fn with_env(mut self, name: &str, value: Option<&str>) -> Self {
        self.env.insert(name.to_string(), value.map(str::to_string));
        self
    }

    fn getenv(&self, name: &str) -> Value {
        let value = match self.env.get(name) {
            Some(value) => value.clone(),
            None => std::env::var(name).ok(),
        };
        value.map(Value::String).unwrap_or(Value::Null)
    }

    /// Call the tool until it answers with something other than `need`.
    fn run(&mut self, mut request: Value) -> Value {
        for _ in 0..32 {
            self.rounds += 1;
            let response = parse(&run_tool(&serde_json::to_vec(&request).unwrap()));
            if self.first_response.is_none() {
                self.first_response = Some(response.clone());
            }
            if response["status"] != "need" {
                return response;
            }
            self.needs.push(response.clone());
            let srctree = request["srctree"].as_str().unwrap().to_string();
            for path in strings(&response["files"]) {
                request["files"][&path] = Self::stat(Path::new(&path));
            }
            for command in strings(&response["shell"]) {
                request["shell"][&command] = Self::shell(&command, &srctree);
            }
            for name in strings(&response["env"]) {
                request["env"][&name] = self.getenv(&name);
            }
        }
        panic!("the module did not finish");
    }

    fn stat(path: &Path) -> Value {
        if !path.exists() {
            return json!({"exists": false, "is_dir": false, "content": null});
        }
        if path.is_dir() {
            return json!({"exists": true, "is_dir": true, "content": null});
        }
        // The file's bytes, as Bazel hands them over.
        let content = String::from_utf8_lossy(&std::fs::read(path).unwrap()).into_owned();
        json!({"exists": true, "is_dir": false, "content": content})
    }

    fn listdir(path: &Path) -> Value {
        if !path.is_dir() {
            return Value::Null;
        }
        let entries: Vec<Value> = std::fs::read_dir(path)
            .unwrap()
            .map(|entry| {
                let entry = entry.unwrap();
                json!([entry.file_name().to_string_lossy(), entry.path().is_dir()])
            })
            .collect();
        Value::Array(entries)
    }

    fn shell(command: &str, srctree: &str) -> Value {
        // The shell `conf` would use for `$(shell,...)`.
        let mut process = if cfg!(windows) {
            let mut process = Command::new("cmd.exe");
            process.arg("/c").arg(command);
            process
        } else {
            let mut process = Command::new("/bin/sh");
            process.arg("-c").arg(command);
            process
        };
        let output = process
            .current_dir(srctree)
            .env("srctree", srctree)
            .output()
            .unwrap();
        json!({
            "stdout": String::from_utf8_lossy(&output.stdout),
            "stderr": String::from_utf8_lossy(&output.stderr),
            "return_code": output.status.code().unwrap_or(-1),
        })
    }

    /// Fill a request as `new_request` in `parser_backend.bzl` does: every
    /// directory's listing, every `Kconfig*` file and the module's variables.
    fn seed(&self, request: &mut Value, srctree: &Path) {
        for name in PARSER_ENV {
            request["env"][name] = self.getenv(name);
        }
        let mut directories = vec![srctree.to_path_buf()];
        while let Some(directory) = directories.pop() {
            request["dirs"][host_path(&directory)] = Self::listdir(&directory);
            for entry in std::fs::read_dir(&directory).unwrap() {
                let path = entry.unwrap().path();
                if path.is_dir() {
                    directories.push(path);
                } else if path
                    .file_name()
                    .unwrap()
                    .to_string_lossy()
                    .starts_with("Kconfig")
                {
                    request["files"][host_path(&path)] = Self::stat(&path);
                }
            }
        }
    }
}

/// A path as Starlark gives one to the tool: absolute, with `/` between its
/// names on every host (`str(repository_ctx.path(...))` on Windows is
/// `C:/...`), which the tool's own paths follow.
fn host_path(path: &Path) -> String {
    std::path::absolute(path)
        .unwrap()
        .to_string_lossy()
        .replace('\\', "/")
}

fn object(fields: Value) -> Map<String, Value> {
    match fields {
        Value::Object(map) => map,
        other => panic!("{other} is an object"),
    }
}

fn request(command: &str, kconfig: &Path, srctree: Option<&Path>, fields: Value) -> Value {
    let srctree = srctree.unwrap_or_else(|| kconfig.parent().unwrap());
    let mut request = object(json!({
        "command": command,
        "env": {},
        "srctree": host_path(srctree),
        "kconfig": host_path(kconfig),
        "files": {},
        "dirs": {},
        "shell": {},
        "parser_version": version(),
    }));
    request.extend(object(fields));
    Value::Object(request)
}

fn repository_request(kconfig: &Path, fields: Value) -> Value {
    let mut request = object(request(
        "repository",
        kconfig,
        None,
        json!({
            "repo_name": "test_kconfig",
            "defaults": null,
            "config_ws_path": null,
            "settings_labels": {},
            "settings_options": {},
        }),
    ));
    request.extend(object(fields));
    Value::Object(request)
}

fn decoded_files(response: &Value) -> BTreeMap<String, String> {
    assert_eq!(response["status"], "ok", "{response}");
    response["files"]
        .as_object()
        .unwrap()
        .iter()
        .map(|(name, content)| (name.clone(), content.as_str().unwrap().to_string()))
        .collect()
}

fn write_tree(root: &Path, files: &[(&str, String)]) {
    for (name, content) in files {
        let path = root.join(name);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, content).unwrap();
    }
}

fn tree() -> Vec<(&'static str, String)> {
    vec![
        (
            "Kconfig",
            r#"mainmenu "Module test"

config FOO
    bool "Enable FOO"
    default n

config COUNT
    int "Count"
    default 3

config LABEL
    string "Label"
    default "héllo"

config ADDR
    hex "Address"
    default 0x1000

config MODULES
    bool
    default y
    {modules}

menu "Drivers"
source "drivers/a/Kconfig"
source "drivers/b/Kconfig"
endmenu

source "extra/Kconfig.extra"

config TAINTED
    string "Tainted"
    default "$(shell,echo from-shell)"

VERSION := $(shell,echo 7)

config INDIRECT
    int "Through a variable"
    default $(VERSION)

choice
    prompt "Pick one"
    default PICK_A

config PICK_A
    bool "A"

config PICK_B
    bool "B"

endchoice
"#
            .replace("{modules}", modules()),
        ),
        (
            "drivers/a/Kconfig",
            "config DRIVER_A\n    tristate \"Driver A\"\n    default y\n".to_string(),
        ),
        (
            "drivers/b/Kconfig",
            "config DRIVER_B\n    bool \"Driver B\"\n    depends on FOO\n    default y\n\n\
             config DRIVER_B_RANGE\n    int \"Ranged\"\n    range 2 9\n    depends on DRIVER_B\n"
                .to_string(),
        ),
        (
            "extra/Kconfig.extra",
            "config EXTRA\n    int \"Extra\"\n    default 7\n\n\
             config QUOTED\n    string \"Quoted\"\n    default \"with \\\"quotes\\\" and \\\\ backslash\"\n"
                .to_string(),
        ),
    ]
}

/// The expected files of a case, by their name in the repository.
fn golden(case: &str) -> BTreeMap<String, String> {
    let root = testdata().join(case);
    let mut files = BTreeMap::new();
    let mut directories = vec![root.clone()];
    while let Some(directory) = directories.pop() {
        for entry in std::fs::read_dir(&directory).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                directories.push(path);
                continue;
            }
            let relative = path
                .strip_prefix(&root)
                .unwrap()
                .to_string_lossy()
                .replace('\\', "/");
            if let Some(name) = relative.strip_suffix(".golden") {
                // As text: a checkout on Windows may have given the goldens
                // CRLF line endings, and the tool writes LF.
                let content = std::fs::read_to_string(&path)
                    .unwrap()
                    .replace("\r\n", "\n");
                files.insert(name.to_string(), content);
            }
        }
    }
    files
}

/// Compare the files of a response with the case's goldens, or rewrite them.
/// The files with the manifest's `srctree`, the tree's path on this host,
/// as a placeholder, for the goldens.
fn without_srctree(files: &BTreeMap<String, String>) -> BTreeMap<String, String> {
    const KEY: &str = "\"srctree\": \"";
    let mut files = files.clone();
    if let Some(manifest) = files.get_mut("kconfig.manifest.json")
        && let Some(start) = manifest.find(KEY)
    {
        let value = start + KEY.len();
        if let Some(len) = manifest[value..].find('"') {
            manifest.replace_range(value..value + len, "<srctree>");
        }
    }
    files
}

fn assert_golden(case: &str, actual: &BTreeMap<String, String>) {
    let actual = &without_srctree(actual);
    if let Some(update) =
        std::env::var_os("KCONFIG_PARSER_GOLDENS").filter(|value| !value.is_empty())
    {
        let root = PathBuf::from(update).join(version()).join(case);
        if root.exists() {
            std::fs::remove_dir_all(&root).unwrap();
        }
        for (name, content) in actual {
            let path = root.join(format!("{name}.golden"));
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, content).unwrap();
        }
        return;
    }
    let expected = golden(case);
    assert_eq!(
        actual.keys().collect::<Vec<_>>(),
        expected.keys().collect::<Vec<_>>()
    );
    for (name, content) in &expected {
        assert_eq!(&actual[name], content, "{case}/{name}");
    }
}

fn contains(files: &BTreeMap<String, String>, name: &str, needle: &str) -> bool {
    files[name].contains(needle)
}

// `command: repository` produces the repository of the goldens.

/// A tree with sources, a choice, a shell macro and a tainted variable.
#[test]
fn repository() {
    let tmp = tmp_path("repository");
    write_tree(&tmp, &tree());
    let mut host = Host::new();
    let response = host.run(repository_request(
        &tmp.join("Kconfig"),
        json!({"settings_options": {"CONFIG_COUNT": ["1", "3"]}}),
    ));
    let files = decoded_files(&response);
    assert_golden("options", &files);
    assert_eq!(
        response["manifest"]["files"],
        json!([
            "Kconfig",
            "drivers/a/Kconfig",
            "drivers/b/Kconfig",
            "extra/Kconfig.extra"
        ])
    );
    assert!(contains(&files, "BUILD.bazel", "default = \"héllo\""));
    // The tainted symbols got the falsey defaults, with the shell run through the host.
    assert!(contains(
        &files,
        "BUILD.bazel",
        "name = \"CONFIG_TAINTED\",\n    build_setting_default = \"\","
    ));
    assert!(contains(
        &files,
        "BUILD.bazel",
        "name = \"CONFIG_INDIRECT\",\n    build_setting_default = 0,"
    ));
}

/// Labeled symbols become aliases, in the BUILD file and the manifest.
#[test]
fn labels() {
    let tmp = tmp_path("labels");
    write_tree(&tmp, &tree());
    let labels = json!({"CONFIG_TAINTED": "@//:tainted", "CONFIG_COUNT": "@//:count"});
    let response = Host::new().run(repository_request(
        &tmp.join("Kconfig"),
        json!({"settings_labels": labels}),
    ));
    let files = decoded_files(&response);
    assert_golden("labels", &files);
    assert_eq!(response["manifest"]["settings_labels"], labels);
}

/// The first round asks for the root file; sources follow as they are found.
#[test]
fn rounds() {
    let tmp = tmp_path("rounds");
    write_tree(&tmp, &tree());
    let mut host = Host::new();
    host.run(repository_request(&tmp.join("Kconfig"), json!({})));
    let first = host.first_response.as_ref().unwrap();
    assert_eq!(first["status"], "need");
    assert_eq!(first["files"], json!([host_path(&tmp.join("Kconfig"))]));
    assert!(
        2 < host.rounds && host.rounds <= 8,
        "{} rounds",
        host.rounds
    );
}

fn level_tree() -> Vec<(&'static str, String)> {
    let mut tree = vec![(
        "Kconfig",
        (0..3)
            .map(|i| format!("source \"level1/{i}/Kconfig\"\n"))
            .collect::<String>(),
    )];
    let level1: [&str; 3] = ["level1/0/Kconfig", "level1/1/Kconfig", "level1/2/Kconfig"];
    let level2: [&str; 3] = ["level2/0/Kconfig", "level2/1/Kconfig", "level2/2/Kconfig"];
    for i in 0..3 {
        tree.push((
            level1[i],
            format!("config L1_{i}\n\tbool\nsource \"level2/{i}/Kconfig\"\n"),
        ));
        tree.push((level2[i], format!("config L2_{i}\n\tbool\n\tdefault y\n")));
    }
    tree
}

fn sorted_files(tree: &[(&str, String)]) -> Vec<String> {
    let mut names: Vec<String> = tree.iter().map(|(name, _)| name.to_string()).collect();
    names.sort();
    names
}

fn sorted_strings(value: &Value) -> Vec<String> {
    let mut items: Vec<String> = strings(value)
        .into_iter()
        .map(|item| item.replace('\\', "/"))
        .collect();
    items.sort();
    items
}

/// Rounds go by the depth of the tree, not the number of files in it.
#[test]
fn a_round_finds_every_file_at_its_level() {
    let tmp = tmp_path("a_round_finds_every_file_at_its_level");
    let tree = level_tree();
    write_tree(&tmp, &tree);
    let mut host = Host::new();
    let response = host.run(repository_request(&tmp.join("Kconfig"), json!({})));
    assert_eq!(response["status"], "ok");
    let level = |prefix: &str| -> Vec<String> {
        let mut paths: Vec<String> = (0..3)
            .map(|i| host_path(&tmp.join(format!("{prefix}/{i}/Kconfig"))))
            .collect();
        paths.sort();
        paths
    };
    let asked: Vec<Vec<String>> = host
        .needs
        .iter()
        .map(|need| sorted_strings(&need["files"]))
        .collect();
    assert_eq!(
        asked,
        vec![
            vec![host_path(&tmp.join("Kconfig"))],
            level("level1"),
            level("level2")
        ]
    );
    assert_eq!(
        sorted_strings(&response["manifest"]["files"]),
        sorted_files(&tree)
    );
}

/// A `source` of a file that does not exist fails as it does natively.
#[test]
fn missing_source_is_an_error() {
    let tmp = tmp_path("missing_source_is_an_error");
    write_tree(
        &tmp,
        &[("Kconfig", "source \"nowhere/Kconfig\"\n".to_string())],
    );
    let response = Host::new().run(repository_request(&tmp.join("Kconfig"), json!({})));
    assert_eq!(response["status"], "error");
    assert!(
        response["message"]
            .as_str()
            .unwrap()
            .contains("nowhere/Kconfig")
    );
}

/// A `.config` of defaults is read through the host and rendered.
#[test]
fn defaults() {
    let tmp = tmp_path("defaults");
    write_tree(&tmp, &tree());
    std::fs::write(
        tmp.join(".config"),
        "CONFIG_FOO=y\nCONFIG_COUNT=42\nCONFIG_TAINTED=\"set\"\nCONFIG_INDIRECT=5\nCONFIG_DRIVER_A=m\nCONFIG_PICK_B=y\n",
    )
    .unwrap();
    let response = Host::new().run(repository_request(
        &tmp.join("Kconfig"),
        json!({
            "defaults": host_path(&tmp.join(".config")),
            "config_ws_path": "defaults/.config",
        }),
    ));
    let files = decoded_files(&response);
    assert_golden("defaults", &files);
    assert!(contains(&files, "rendered.config", "CONFIG_COUNT=42"));
    assert!(contains(
        &files,
        "BUILD.bazel",
        "config = \"defaults/.config\""
    ));
}

/// The generator's exit with a message becomes an error response.
#[test]
fn missing_tainted_default_is_an_error() {
    let tmp = tmp_path("missing_tainted_default_is_an_error");
    write_tree(&tmp, &tree());
    std::fs::write(tmp.join(".config"), "CONFIG_FOO=y\n").unwrap();
    let response = Host::new().run(repository_request(
        &tmp.join("Kconfig"),
        json!({
            "defaults": host_path(&tmp.join(".config")),
            "config_ws_path": ".config",
        }),
    ));
    assert_eq!(response["status"], "error");
    let message = response["message"].as_str().unwrap();
    assert!(
        message.contains("CONFIG_TAINTED uses $(shell,...)"),
        "{message}"
    );
    assert!(
        message.contains("CONFIG_INDIRECT uses $(shell,...)"),
        "{message}"
    );
}

/// A root Kconfig that does not exist is reported, not retried.
#[test]
fn missing_root_is_an_error() {
    let tmp = tmp_path("missing_root_is_an_error");
    let response = Host::new().run(repository_request(&tmp.join("Kconfig"), json!({})));
    assert_eq!(response["status"], "error");
    assert!(response["message"].as_str().unwrap().contains("Kconfig"));
}

/// `command: overrides` produces the repository of the goldens: overrides
/// stacked on a base config, the tree read through the host.
#[test]
fn overrides() {
    let tmp = tmp_path("overrides");
    let srcs = tmp.join("kconfig_srcs");
    write_tree(&srcs, &tree());
    // The base is the tree's own repository, as `plain` has it.
    std::fs::write(
        tmp.join("rendered.config"),
        &golden("plain")["rendered.config"],
    )
    .unwrap();
    let config = tmp.join("override.config");
    std::fs::write(
        &config,
        "CONFIG_FOO=y\nCONFIG_COUNT=42\nCONFIG_TAINTED=\"x\"\nCONFIG_INDIRECT=1\n",
    )
    .unwrap();

    let response = Host::new().run(request(
        "overrides",
        &srcs.join("Kconfig"),
        Some(&srcs),
        json!({
            "config": host_path(&config),
            "base_config": host_path(&tmp.join("rendered.config")),
            "kconfig_repo": "@@ext+",
            "config_ws_path": "override.config",
            "settings_labels": {},
        }),
    ));
    let files = decoded_files(&response);
    assert_golden("overrides", &files);
    assert!(contains(
        &files,
        "defs.bzl",
        "\"@@ext+//:CONFIG_COUNT\": 42"
    ));
    assert_eq!(response["manifest"], Value::Null);
}

/// A command the module does not know is an error.
#[test]
fn unknown_command_is_an_error() {
    let tmp = tmp_path("unknown_command_is_an_error");
    let response = Host::new().run(request("nonsense", &tmp.join("Kconfig"), None, json!({})));
    assert_eq!(response["status"], "error");
    assert!(
        response["message"]
            .as_str()
            .unwrap()
            .contains("unknown command")
    );
}

/// A payload that is not JSON is an error, not a crash.
#[test]
fn malformed_payload_is_an_error() {
    let response = parse(&run_tool(b"not json"));
    assert_eq!(response["status"], "error");
}

fn replace_bytes(haystack: &[u8], needle: &[u8], replacement: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(haystack.len());
    let mut i = 0;
    while i < haystack.len() {
        if haystack[i..].starts_with(needle) {
            out.extend_from_slice(replacement);
            i += needle.len();
        } else {
            out.push(haystack[i]);
            i += 1;
        }
    }
    out
}

fn contains_bytes(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

/// A byte that is not UTF-8 in a source comes back as it went in.
#[test]
fn bytes_pass_through() {
    let tmp = tmp_path("bytes_pass_through");
    std::fs::write(
        tmp.join("Kconfig"),
        b"config LATIN\n\tstring \"Latin\"\n\tdefault \"caf\xe9\"\n",
    )
    .unwrap();
    let host = Host::new();
    let mut request = repository_request(&tmp.join("Kconfig"), json!({}));
    // The host reads the file lossily, as this test's JSON library cannot
    // carry the byte; the payload gets it back before it is sent, as
    // Starlark would have handed it over.
    host.seed(&mut request, &tmp);
    let payload = replace_bytes(
        &serde_json::to_vec(&request).unwrap(),
        "caf\u{FFFD}".as_bytes(),
        b"caf\xe9",
    );
    assert!(contains_bytes(&payload, b"caf\xe9"));
    let response = run_tool(&payload);
    assert!(contains_bytes(&response, b"caf\xe9"));
    // The expectation is spelled out: the bytes pass through as they came,
    // inside the JSON encoding of the BUILD file.
    assert!(contains_bytes(
        &response,
        b"name = \\\"CONFIG_LATIN\\\",\\n    build_setting_default = \\\"caf\xe9\\\",",
    ));
    let decoded = parse(&replace_bytes(&response, b"\xe9", b"?"));
    assert_eq!(decoded["status"], "ok", "{decoded}");
}

/// Drive paths, which POSIX rules would not treat as absolute: every path
/// asked of Starlark is `C:/...`, never `/C:/...`.
#[test]
fn paths_are_returned_in_host_form() {
    let files: BTreeMap<&str, &str> = BTreeMap::from([
        (
            "C:/tree/Kconfig",
            "mainmenu \"Win\"\n\nconfig A\n\tbool \"A\"\n\nsource \"sub/Kconfig\"\n",
        ),
        (
            "C:/tree/sub/Kconfig",
            "config B\n\tint \"B\"\n\tdefault 2\n",
        ),
    ]);
    let mut request = json!({
        "command": "repository",
        "env": {},
        "srctree": "C:/tree",
        "kconfig": "C:/tree/Kconfig",
        "files": {},
        "dirs": {},
        "shell": {},
        "repo_name": "win_kconfig",
        "defaults": null,
        "config_ws_path": null,
        "settings_labels": {},
        "settings_options": {},
    });
    // Answer requests from `files`, as Starlark on Windows would, by host path.
    let mut response = Value::Null;
    for _ in 0..10 {
        response = parse(&run_tool(&serde_json::to_vec(&request).unwrap()));
        if response["status"] != "need" {
            break;
        }
        for path in strings(&response["files"]) {
            let key = path.replace('\\', "/");
            assert!(!key.starts_with('/'), "{path}");
            let content = files.get(key.as_str());
            request["files"][&path] = json!({
                "exists": content.is_some(),
                "is_dir": false,
                "content": content,
            });
        }
        for name in strings(&response["env"]) {
            request["env"][&name] = Value::Null;
        }
        assert!(strings(&response["shell"]).is_empty());
    }
    assert_eq!(response["status"], "ok", "{response}");
    assert_eq!(
        response["manifest"]["files"],
        json!(["Kconfig", "sub/Kconfig"])
    );
    assert_eq!(response["manifest"]["root"], "Kconfig");
    let generated = decoded_files(&response);
    assert!(contains(
        &generated,
        "BUILD.bazel",
        "name = \"CONFIG_B\",\n    build_setting_default = 2,"
    ));
    let asked: BTreeSet<String> = request["files"]
        .as_object()
        .unwrap()
        .keys()
        .map(|path| path.replace('\\', "/"))
        .collect();
    assert_eq!(asked, files.keys().map(|key| key.to_string()).collect());
}

/// With the tree read ahead there is nothing left to ask for.
#[test]
fn a_seeded_request_finishes_in_one_round() {
    let tmp = tmp_path("a_seeded_request_finishes_in_one_round");
    let tree = level_tree();
    write_tree(&tmp, &tree);
    let mut host = Host::new();
    let mut request = repository_request(&tmp.join("Kconfig"), json!({}));
    host.seed(&mut request, &tmp);
    let response = host.run(request);
    assert_eq!(response["status"], "ok");
    assert_eq!(host.rounds, 1);
    assert_eq!(
        sorted_strings(&response["manifest"]["files"]),
        sorted_files(&tree)
    );
}

/// A `source` of a file that is not in its directory's listing costs no round.
#[test]
fn a_listed_directory_answers_for_a_missing_file() {
    let tmp = tmp_path("a_listed_directory_answers_for_a_missing_file");
    write_tree(
        &tmp,
        &[("Kconfig", "source \"optional/Kconfig\"\n".to_string())],
    );
    std::fs::create_dir(tmp.join("optional")).unwrap();
    let mut host = Host::new();
    let mut request = repository_request(&tmp.join("Kconfig"), json!({}));
    host.seed(&mut request, &tmp);
    let response = host.run(request);
    assert_eq!(response["status"], "error");
    assert!(
        response["message"]
            .as_str()
            .unwrap()
            .contains("optional/Kconfig")
    );
    assert_eq!(host.rounds, 1);
}

/// `$(NAME)` names a variable the request did not carry; the next round has it.
#[test]
fn a_variable_is_asked_for_when_met() {
    let tmp = tmp_path("a_variable_is_asked_for_when_met");
    write_tree(
        &tmp,
        &[(
            "Kconfig",
            "config BOARD\n\tstring\n\tdefault \"$(MODULE_TEST_BOARD)\"\n\
             config FALLBACK\n\tstring\n\tdefault \"$(MODULE_TEST_UNSET)none\"\n"
                .to_string(),
        )],
    );
    let mut host = Host::new()
        .with_env("MODULE_TEST_BOARD", Some("k2"))
        .with_env("MODULE_TEST_UNSET", None);
    let mut request = repository_request(&tmp.join("Kconfig"), json!({}));
    host.seed(&mut request, &tmp);
    let response = host.run(request);
    assert_eq!(response["status"], "ok");
    let asked: Vec<Vec<String>> = host
        .needs
        .iter()
        .map(|need| sorted_strings(&need["env"]))
        .collect();
    assert_eq!(
        asked,
        vec![vec![
            "MODULE_TEST_BOARD".to_string(),
            "MODULE_TEST_UNSET".to_string()
        ]]
    );
    let files = decoded_files(&response);
    assert!(contains(
        &files,
        "BUILD.bazel",
        "name = \"CONFIG_BOARD\",\n    build_setting_default = \"k2\","
    ));
    assert!(contains(
        &files,
        "BUILD.bazel",
        "name = \"CONFIG_FALLBACK\",\n    build_setting_default = \"none\","
    ));
    assert_golden("env", &files);
}

/// The trees of examples/simple and examples/settings_labels, which CI also
/// generates with the module itself.
fn example(name: &str) -> String {
    let text = match name {
        "simple" => {
            "# Minimal Kconfig for rules_kconfig examples.\n\
             # See https://www.kernel.org/doc/html/latest/kbuild/kconfig-language.html\n\
             \n\
             mainmenu \"Simple example Kconfig\"\n\
             \n\
             config FOO\n\tbool \"Enable FOO\"\n\tdefault n\n\thelp\n\t  Example boolean option.\n\
             \n\
             config COUNT\n\tint \"Count\"\n\tdefault 3\n\thelp\n\t  Example integer option.\n\
             \n\
             config LABEL\n\tstring \"Label\"\n\tdefault \"hello\"\n\thelp\n\t  Example string option.\n\
             \n\
             config BASE_ADDR\n\thex \"Base address\"\n\tdefault 0x1000\n\thelp\n\t  Example hex option.\n\
             \n\
             config NUMERIC_STRING\n\tstring \"A string that looks like a number\"\n\tdefault \"42\"\n\thelp\n\
             \t  A string symbol is always quoted in config.h, whatever it holds.\n\
             \n\
             config EMPTY\n\tstring \"An empty string\"\n\tdefault \"\"\n\thelp\n\
             \t  A string set to \"\" is set: config.h defines it as \"\".\n\
             \n\
             config DEPENDENT_COUNT\n\tint \"Count behind FOO\"\n\tdepends on FOO\n\tdefault 5\n\thelp\n\
             \t  Generated with FOO at its default of n, this has no value, and\n\
             \t  config.h leaves it undefined rather than defining it as 0.\n\
             \n\
             config MODULES\n\tbool\n\tdefault y\n\t{modules}\n\thelp\n\t  Lets tristate symbols take the value m.\n\
             \n\
             config TRISTATE\n\ttristate \"Tristate Feature support\"\n\thelp\n\t  Example tristate option.\n"
        }
        "settings_labels" => {
            "# Kconfig demonstrating setting_labels for shell-tainted symbols.\n\
             \n\
             mainmenu \"Setting Labels example\"\n\
             \n\
             config ENABLED\n\tbool \"Enable feature\"\n\tdefault n\n\thelp\n\t  Example boolean option.\n\
             \n\
             config VERSION\n\tint\n\tdefault $(shell,echo 99)\n\thelp\n\
             \t  Version derived from the build environment.\n\
             \t  The $(shell,...) default cannot be resolved at repository-rule\n\
             \t  time; use setting_labels to supply the value from a custom rule.\n"
        }
        _ => unreachable!(),
    };
    text.replace("{modules}", modules())
}

/// The example trees generate the repositories of their goldens.
fn check_example(name: &str) {
    let tmp = tmp_path(&format!("example_{name}"));
    std::fs::write(tmp.join("Kconfig"), example(name)).unwrap();
    let labels = if name == "settings_labels" {
        json!({"CONFIG_VERSION": "@//:version"})
    } else {
        json!({})
    };
    let response = Host::new().run(repository_request(
        &tmp.join("Kconfig"),
        json!({"settings_labels": labels}),
    ));
    assert_golden(&format!("example_{name}"), &decoded_files(&response));
}

#[test]
fn example_simple() {
    check_example("simple");
}

#[test]
fn example_settings_labels() {
    check_example("settings_labels");
}

/// The request names the kernel release whose parser to use; one the tool
/// has not is an error naming the ones it has, and the manifest records the
/// one used.
#[test]
fn the_parser_of_the_request() {
    let tmp = tmp_path("the_parser_of_the_request");
    write_tree(
        &tmp,
        &[(
            "Kconfig",
            "config A\n\tbool \"A\"\n\tdefault y\n".to_string(),
        )],
    );
    let response = Host::new().run(repository_request(&tmp.join("Kconfig"), json!({})));
    assert_eq!(response["manifest"]["parser_version"], version());
    assert_eq!(response["manifest"]["kconfig_version"], version());
    let response = Host::new().run(repository_request(
        &tmp.join("Kconfig"),
        json!({"parser_version": "3.0"}),
    ));
    assert_eq!(response["status"], "error", "{response}");
    let message = response["message"].as_str().unwrap();
    assert!(
        message.contains("3.0") && message.contains(&version()),
        "{message}"
    );
    // Without one, the newest.
    let mut request = repository_request(&tmp.join("Kconfig"), json!({}));
    request.as_object_mut().unwrap().remove("parser_version");
    let response = Host::new().run(request);
    assert_eq!(response["status"], "ok", "{response}");
}

/// With two arguments the tool reads the request from a file and writes the
/// response to another, as the repository rules run it.
#[test]
fn files_in_and_out() {
    let tmp = tmp_path("files_in_and_out");
    write_tree(
        &tmp,
        &[(
            "Kconfig",
            "config A\n\tbool \"A\"\n\tdefault y\n".to_string(),
        )],
    );
    let mut request = repository_request(&tmp.join("Kconfig"), json!({}));
    Host::new().seed(&mut request, &tmp);
    let request_path = tmp.join("request.json");
    let response_path = tmp.join("response.json");
    std::fs::write(&request_path, serde_json::to_vec(&request).unwrap()).unwrap();
    let output = Command::new(tool())
        .arg(&request_path)
        .arg(&response_path)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(output.stdout.is_empty());
    let response = parse(&std::fs::read(&response_path).unwrap());
    assert_eq!(response["status"], "ok", "{response}");
    assert!(
        response["files"]["rendered.config"]
            .as_str()
            .unwrap()
            .contains("CONFIG_A=y")
    );

    let output = Command::new(tool()).arg("one").output().unwrap();
    assert!(!output.status.success());
    assert!(contains_bytes(&output.stderr, b"usage"));
}

/// An int with a range and no default takes the bound, as `conf` has it.
///
/// The kernel's range check clamps the value to the bound it falls outside
/// of, a named bound calculated as it is read; the kernel's lib/Kconfig has
/// `BCH_CONST_M` so.
#[test]
fn a_range_bound_is_calculated_before_it_is_read() {
    let tmp = tmp_path("a_range_bound_is_calculated_before_it_is_read");
    write_tree(
        &tmp,
        &[(
            "Kconfig",
            "config BOUNDED\n\tint\n\trange 5 15\n\
             config LOW\n\tint\n\tdefault 3\n\
             config NAMED_BOUNDS\n\tint\n\trange LOW 9\n\
             config PROMPTED\n\tint \"Prompted\"\n\trange 5 15\n"
                .to_string(),
        )],
    );
    let response = Host::new().run(repository_request(&tmp.join("Kconfig"), json!({})));
    let files = decoded_files(&response);
    assert!(contains(
        &files,
        "BUILD.bazel",
        "name = \"CONFIG_BOUNDED\",\n    build_setting_default = 5,"
    ));
    assert!(contains(
        &files,
        "BUILD.bazel",
        "name = \"CONFIG_NAMED_BOUNDS\",\n    build_setting_default = 3,"
    ));
    // Without a prompt the symbols above are not written; with one the
    // clamped value is.
    assert!(contains(&files, "rendered.config", "CONFIG_PROMPTED=5\n"));
}

/// With `write_invisible`, a symbol the configuration makes invisible is
/// written as BusyBox's kconfig writes it: in its place in the tree's order,
/// not set or with the type's empty value, and `config.h` defines it so (no
/// `unset`). Without, the Linux tools' way: left out of `rendered.config`,
/// and undefined. The manifest records it, and an overrides repository
/// layered on the repository writes its `rendered.config` the same way.
#[test]
fn write_invisible_writes_every_symbol() {
    let tmp = tmp_path("write_invisible_writes_every_symbol");
    write_tree(
        &tmp,
        &[(
            "Kconfig",
            "config OFF\n\tbool\n\
             config PATH\n\tstring \"Path\"\n\tdefault \"/sbin/telinit\"\n\tdepends on OFF\n\
             config DELAY\n\tint \"Delay\"\n\tdefault 3\n\tdepends on OFF\n\
             config FLAG\n\tbool \"Flag\"\n\tdefault y\n\tdepends on OFF\n\
             config SHOWN\n\tstring \"Shown\"\n\tdefault \"x\"\n"
                .to_string(),
        )],
    );
    let files =
        decoded_files(&Host::new().run(repository_request(&tmp.join("Kconfig"), json!({}))));
    assert!(!contains(&files, "rendered.config", "CONFIG_PATH"));
    let unset = files["BUILD.bazel"].split("unset = [").nth(1).unwrap();
    assert!(
        unset.contains("\"CONFIG_PATH\",\n        \"CONFIG_DELAY\",\n        \"CONFIG_FLAG\",")
    );

    let response = Host::new().run(repository_request(
        &tmp.join("Kconfig"),
        json!({"write_invisible": true}),
    ));
    assert_eq!(response["manifest"]["write_invisible"], json!(true));
    let files = decoded_files(&response);
    assert!(
        files["rendered.config"].ends_with(
            "# CONFIG_OFF is not set\nCONFIG_PATH=\"\"\nCONFIG_DELAY=0\n# CONFIG_FLAG is not set\nCONFIG_SHOWN=\"x\"\n"
        ),
        "{}",
        files["rendered.config"]
    );
    assert!(!contains(&files, "BUILD.bazel", "unset = ["));
    assert!(contains(
        &files,
        "BUILD.bazel",
        "name = \"CONFIG_PATH\",\n    build_setting_default = \"\","
    ));

    // An overrides repository is given the manifest's `write_invisible`.
    let config = tmp.join("override.config");
    std::fs::write(&config, "CONFIG_SHOWN=\"y\"\n").unwrap();
    let files = decoded_files(&Host::new().run(request(
        "overrides",
        &tmp.join("Kconfig"),
        Some(&tmp),
        json!({
            "config": host_path(&config),
            "kconfig_repo": "@@ext+",
            "settings_labels": {},
            "write_invisible": true,
        }),
    )));
    assert!(
        files["rendered.config"].ends_with(
            "# CONFIG_OFF is not set\nCONFIG_PATH=\"\"\nCONFIG_DELAY=0\n# CONFIG_FLAG is not set\nCONFIG_SHOWN=\"y\"\n"
        ),
        "{}",
        files["rendered.config"]
    );
}

/// A shell-tainted symbol without a prompt, or whose prompt's condition does
/// not hold, cannot be set by a defaults file; it is not an error that the
/// file leaves it out, and it keeps the value the tools calculate. One the
/// file sets takes the value set.
#[test]
fn a_symbol_no_config_can_set_keeps_the_calculated_value() {
    let tmp = tmp_path("a_symbol_no_config_can_set_keeps_the_calculated_value");
    write_tree(
        &tmp,
        &[(
            "Kconfig",
            "config PROBE\n\tbool\n\tdefault $(shell,echo y)\n\
             config OFF\n\tbool\n\
             config HIDDEN\n\tint \"Hidden\"\n\tdepends on OFF\n\tdefault $(shell,echo 4)\n\
             config SET\n\tint \"Set\"\n\tdefault $(shell,echo 8)\n"
                .to_string(),
        )],
    );
    let fields = json!({
        "defaults": host_path(&tmp.join(".config")),
        "config_ws_path": ".config",
    });
    std::fs::write(tmp.join(".config"), "CONFIG_SET=2\n").unwrap();
    let response = Host::new().run(repository_request(&tmp.join("Kconfig"), fields.clone()));
    let files = decoded_files(&response);
    let build = &files["BUILD.bazel"];
    assert!(build.contains("name = \"CONFIG_PROBE\",\n    build_setting_default = True,"));
    assert!(build.contains("name = \"CONFIG_HIDDEN\",\n    build_setting_default = 0,"));
    assert!(build.contains("name = \"CONFIG_SET\",\n    build_setting_default = 2,"));

    std::fs::write(tmp.join(".config"), "").unwrap();
    let response = Host::new().run(repository_request(&tmp.join("Kconfig"), fields));
    assert_eq!(response["status"], "error");
    let message = response["message"].as_str().unwrap();
    assert!(
        message.contains("CONFIG_SET uses $(shell,...)"),
        "{message}"
    );
    assert!(!message.contains("CONFIG_PROBE"), "{message}");
    assert!(!message.contains("CONFIG_HIDDEN"), "{message}");
}

/// What the `$(shell,...)` commands answered is kept in the manifest, and an
/// overrides repository given the answers asks the host for none.
#[test]
fn the_shell_answers_are_recorded_and_replayed() {
    let tmp = tmp_path("the_shell_answers_are_recorded_and_replayed");
    write_tree(
        &tmp,
        &[(
            "Kconfig",
            "config PROBED\n\tstring\n\tdefault \"$(shell,echo probed)\"\n\
             config SET\n\tint \"Set\"\n\tdefault 1\n"
                .to_string(),
        )],
    );
    let response = Host::new().run(repository_request(&tmp.join("Kconfig"), json!({})));
    // As text on every host: cmd.exe's `echo` ends the line with CRLF, which
    // the manifest keeps as LF.
    assert_eq!(
        response["manifest"]["shell"],
        json!({"echo probed": "probed\n"})
    );
    let files = decoded_files(&response);
    assert!(contains(
        &files,
        "rendered.config",
        "CONFIG_PROBED=\"probed\"\n"
    ));

    let config = tmp.join("override.config");
    std::fs::write(&config, "CONFIG_SET=2\n").unwrap();
    let mut request = request(
        "overrides",
        &tmp.join("Kconfig"),
        Some(&tmp),
        json!({
            "config": host_path(&config),
            "kconfig_repo": "@@ext+",
            "settings_labels": {},
        }),
    );
    request["shell"]["echo probed"] = json!({"stdout": "as recorded\n"});
    let mut host = Host::new();
    let files = decoded_files(&host.run(request));
    assert!(contains(
        &files,
        "rendered.config",
        "CONFIG_PROBED=\"as recorded\"\nCONFIG_SET=2\n"
    ));
    assert!(
        host.needs
            .iter()
            .all(|need| strings(&need["shell"]).is_empty())
    );
}

/// The variables of the `env` attribute, which Starlark merges into the
/// request's, are kept in the manifest for an overrides repository.
#[test]
fn the_variables_given_are_recorded() {
    let tmp = tmp_path("the_variables_given_are_recorded");
    write_tree(
        &tmp,
        &[(
            "Kconfig",
            "config BOARD\n\tstring\n\tdefault \"$(MODULE_TEST_BOARD)\"\n".to_string(),
        )],
    );
    let mut request = repository_request(
        &tmp.join("Kconfig"),
        json!({"kconfig_env": {"MODULE_TEST_BOARD": "k3"}}),
    );
    request["env"]["MODULE_TEST_BOARD"] = json!("k3");
    let mut host = Host::new();
    let response = host.run(request);
    let files = decoded_files(&response);
    assert!(contains(
        &files,
        "BUILD.bazel",
        "name = \"CONFIG_BOARD\",\n    build_setting_default = \"k3\","
    ));
    assert_eq!(
        response["manifest"]["env"],
        json!({"MODULE_TEST_BOARD": "k3"})
    );
    assert!(contains(
        &files,
        "kconfig.manifest.json",
        "\"env\": {\n    \"MODULE_TEST_BOARD\": \"k3\"\n  }"
    ));
    // Given ahead, the variable was never asked for.
    assert!(host.needs.iter().all(|need| {
        !strings(&need["env"])
            .iter()
            .any(|name| name == "MODULE_TEST_BOARD")
    }));
}

/// A tree with CRLF line endings, as a checkout on Windows may have, parses
/// as the same tree with LF: the shim reads files as text. The kernel's
/// lexer alone would keep the `\r` at the end of a variable's value.
#[test]
fn crlf_line_endings_read_as_text() {
    let tmp = tmp_path("crlf_line_endings_read_as_text");
    let text = "VERSION := $(shell,echo 7)\r\nconfig INDIRECT\r\n\tint \"Through a variable\"\r\n\tdefault $(VERSION)\r\n";
    std::fs::write(tmp.join("Kconfig"), text).unwrap();
    assert!(contains_bytes(
        &std::fs::read(tmp.join("Kconfig")).unwrap(),
        b"\r\n"
    ));
    let response = Host::new().run(repository_request(&tmp.join("Kconfig"), json!({})));
    let files = decoded_files(&response);
    assert!(contains(&files, "rendered.config", "CONFIG_INDIRECT=7\n"));
    // Tainted and visible, the flag keeps the falsey default; the name
    // itself came through without the `\r`.
    assert!(contains(
        &files,
        "BUILD.bazel",
        "name = \"CONFIG_INDIRECT\",\n    build_setting_default = 0,"
    ));
}
