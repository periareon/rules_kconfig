"""The WebAssembly backend that belongs to this release of rules_kconfig.

`.github/workflows/release_prep.sh` builds `kconfig.wasm` with Bazel
(`//kconfig/private/wasm:kconfig_wasm`), attaches it to the GitHub release and
fills in `MODULE_INTEGRITY` below in the copy of this file that goes into the
module archive. The `kconfig` extension of that release downloads the module
from here, through Bazel's repository cache, the first time a repository is
generated with it.

A source checkout carries no integrity and so no module; the environment
variable `RULES_KCONFIG_WASM` names one instead (see `wasm_backend.bzl`).
"""

load("//:version.bzl", "VERSION")

MODULE_URL = "https://github.com/periareon/rules_kconfig/releases/download/{}/kconfig.wasm".format(VERSION)

# Filled in by release_prep.sh; empty in a source checkout.
MODULE_INTEGRITY = ""
