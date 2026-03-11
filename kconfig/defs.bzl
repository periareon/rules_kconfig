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
    config = "//:Kconfig",
    interpreter = "@python_3_12_host//:python",
)
use_repo(kconfig, "my_kconfig")
```

See the [Introduction](./index.md) for full setup and usage instructions.
"""

load(
    ":extensions.bzl",
    _kconfig = "kconfig",
)
load(
    ":kconfig_repository.bzl",
    _kconfig_repository = "kconfig_repository",
)

kconfig = _kconfig
kconfig_repository = _kconfig_repository
