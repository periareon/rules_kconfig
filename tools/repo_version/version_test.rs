//! Checks that `version.bzl` and `MODULE.bazel` name the same release.

use std::path::PathBuf;

use runfiles::{Runfiles, rlocation};

fn read(variable: &str) -> String {
    let runfiles = Runfiles::create().expect("the runfiles");
    let rlocationpath = std::env::var(variable).unwrap_or_else(|_| panic!("{variable} is set"));
    let path: PathBuf = rlocation!(runfiles, &rlocationpath)
        .unwrap_or_else(|| panic!("{rlocationpath} is in the runfiles"));
    std::fs::read_to_string(&path).unwrap_or_else(|error| panic!("{}: {error}", path.display()))
}

/// The value of `name = "..."` on a line, if the line is one.
fn quoted(line: &str, name: &str) -> Option<String> {
    line.trim()
        .strip_prefix(name)?
        .trim_start()
        .strip_prefix('=')?
        .trim()
        .trim_end_matches(',')
        .strip_prefix('"')?
        .strip_suffix('"')
        .map(str::to_string)
}

#[test]
fn versions_match() {
    let version_bzl = read("VERSION_BZL");
    let bzl_version = version_bzl
        .lines()
        .find_map(|line| quoted(line, "VERSION"))
        .expect("version.bzl has `VERSION = \"...\"`");

    let module_bazel = read("MODULE_BAZEL");
    let module = module_bazel
        .split_once("module(")
        .and_then(|(_, rest)| rest.split_once(')'))
        .map(|(block, _)| block)
        .expect("MODULE.bazel has a `module(...)`");
    assert_eq!(
        module
            .lines()
            .find_map(|line| quoted(line, "name"))
            .as_deref(),
        Some("rules_kconfig")
    );
    let module_version = module
        .lines()
        .find_map(|line| quoted(line, "version"))
        .expect("module(...) has a version");

    assert_eq!(bzl_version, module_version);
}
