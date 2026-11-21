"""# rules_kconfig

Bazel rules for parsing [Kconfig](https://www.kernel.org/doc/html/latest/kbuild/kconfig-language.html)
files and generating equivalent Bazel build settings and `config.h` headers.

## Module extension

The primary interface is the `kconfig` module extension. Each `kconfig.repo`
tag parses a Kconfig file tree and generates a repository containing:

- A `bool_flag`, `int_flag`, or `string_flag` for every `config` symbol.
- A `cc_library` target (`:config`) that provides `config.h` reflecting
  the active flag values.

```python
kconfig = use_extension("@rules_kconfig//kconfig:extensions.bzl", "kconfig")
kconfig.repo(
    name = "my_kconfig",
    kconfig = "//:Kconfig",
)
use_repo(kconfig, "my_kconfig")
```

The tree is parsed by the Linux kernel's Kconfig parser, which a release of
rules_kconfig publishes as a WebAssembly module (Bazel 9.3 or newer with
`--experimental_repository_ctx_execute_wasm`) and as a native build per
platform; no Python interpreter is needed.

Use `kconfig.overrides` to overlay a `.config` file onto an external kconfig
repository via a Starlark transition:

```python
kconfig.overrides(
    name = "my_board_config",
    kconfig = "@ext_kconfig//:ext_kconfig",
    config = "//:.config",
)
use_repo(kconfig, "my_board_config")
```

See the [Introduction](./index.md) for full setup and usage instructions.
"""

load(
    "//kconfig/private:kconfig_settings_group.bzl",
    _KconfigSettingsInfo = "KconfigSettingsInfo",
)
load(
    ":extensions.bzl",
    _kconfig = "kconfig",
)
load(
    ":kconfig_info.bzl",
    _KConfigInfo = "KConfigInfo",
)
load(
    ":kconfig_library.bzl",
    _kconfig_library = "kconfig_library",
)
load(
    ":kconfig_overrides_repository.bzl",
    _kconfig_overrides_repository = "kconfig_overrides_repository",
)
load(
    ":kconfig_repository.bzl",
    _kconfig_repository = "kconfig_repository",
)
load(
    ":kconfig_toolchain.bzl",
    _kconfig_toolchain = "kconfig_toolchain",
)
load(
    ":make_variable_setting.bzl",
    _make_variable_setting = "make_variable_setting",
)
load(
    ":menuconfig.bzl",
    _menuconfig = "menuconfig",
)

kconfig = _kconfig
kconfig_library = _kconfig_library
kconfig_overrides_repository = _kconfig_overrides_repository
kconfig_repository = _kconfig_repository
kconfig_toolchain = _kconfig_toolchain
KConfigInfo = _KConfigInfo
KconfigSettingsInfo = _KconfigSettingsInfo
make_variable_setting = _make_variable_setting
menuconfig = _menuconfig
