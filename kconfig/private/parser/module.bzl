"""The parser builds that belong to this release of rules_kconfig.

`.github/workflows/release_prep.sh` attaches `kconfig.wasm`, built with Bazel
for `wasm32-wasip1` (`//kconfig/private/parser:kconfig_wasm`), and a native
build of the same program per platform, `kconfig_tool-<os>-<cpu>`, to the
GitHub release, and fills in the integrities below in the copy of this file
that goes into the module archive. The `kconfig` extension of that release
downloads what the host can run, through Bazel's repository cache, the first
time a repository is generated with it.

A source checkout carries no integrities and so no builds; the environment
variables `RULES_KCONFIG_WASM` and `RULES_KCONFIG_TOOL` name them instead
(see `parser_backend.bzl`). A build has the parsers of every kernel release
`//kconfig/private:versions.bzl` lists.
"""

load("//:version.bzl", "VERSION")

_RELEASE = "https://github.com/periareon/rules_kconfig/releases/download/{}".format(VERSION)

MODULE_URL = _RELEASE + "/kconfig.wasm"

# Filled in by release_prep.sh; empty in a source checkout.
MODULE_INTEGRITY = ""

# The native builds, by `<os>-<cpu>` of the host that runs them.
TOOL_URLS = {
    "linux-aarch64": _RELEASE + "/kconfig_tool-linux-aarch64",
    "linux-x86_64": _RELEASE + "/kconfig_tool-linux-x86_64",
    "macos-aarch64": _RELEASE + "/kconfig_tool-macos-aarch64",
    "windows-aarch64": _RELEASE + "/kconfig_tool-windows-aarch64.exe",
    "windows-x86_64": _RELEASE + "/kconfig_tool-windows-x86_64.exe",
}

# Filled in by release_prep.sh for the platforms the release built; empty in
# a source checkout, and for a platform the release has no build for.
TOOL_INTEGRITIES = {
    "linux-aarch64": "",
    "linux-x86_64": "",
    "macos-aarch64": "",
    "windows-aarch64": "",
    "windows-x86_64": "",
}
