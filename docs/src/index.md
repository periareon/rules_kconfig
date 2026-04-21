# rules_kconfig

Bazel rules for parsing [Kconfig](https://www.kernel.org/doc/html/latest/kbuild/kconfig-language.html)
files and generating equivalent Bazel build settings.

A kconfig repository exposes each `config` symbol as a Bazel
[build setting](https://bazel.build/extending/config) flag
(`bool_flag`, `int_flag`, or `string_flag`) whose default matches the
Kconfig-declared default. It also generates a `config.h` header (via
[rules_cc_autoconf](https://github.com/periareon/rules_cc_autoconf)) that
reflects the active flag values, so C/C++ code can consume the configuration
with `#include "config.h"`.

## Setup

Add the dependency to your `MODULE.bazel`:

```python
bazel_dep(name = "rules_kconfig", version = "{version}")
```

A Python toolchain is required for parsing. Configure one with
[rules_python](https://github.com/bazelbuild/rules_python):

```python
python = use_extension("@rules_python//python/extensions:python.bzl", "python")
python.toolchain(python_version = "3.12")
use_repo(python, "python_3_12_host")
```

Then register a kconfig repository via the module extension:

```python
kconfig = use_extension("@rules_kconfig//kconfig:extensions.bzl", "kconfig")
kconfig.repo(
    name = "my_kconfig",
    kconfig = "//:Kconfig",
    interpreter = "@python_3_12_host//:python",
)
use_repo(kconfig, "my_kconfig")
```

## Generated repository

For a Kconfig file such as:

```text
config FOO
    bool "Enable FOO"
    default n

config COUNT
    int "Count"
    default 3
```

The generated repository `@my_kconfig` contains:

| Target                                 | Description                                   |
| -------------------------------------- | --------------------------------------------- |
| `@my_kconfig//:CONFIG_FOO`             | `bool_flag` (default `False`)                 |
| `@my_kconfig//:CONFIG_COUNT`           | `int_flag` (default `3`)                      |
| `@my_kconfig//:config`                 | `cc_library` providing `config.h`             |
| `@my_kconfig//settings.CONFIG_FOO`     | `config_setting` matching `CONFIG_FOO = true` |
| `@my_kconfig//settings.CONFIG_COUNT_3` | `config_setting` matching `CONFIG_COUNT = 3`  |

## Usage

### Setting flag values

Flags can be set on the command line or in `.bazelrc`:

```text
build --@my_kconfig//:CONFIG_FOO=true
build --@my_kconfig//:CONFIG_COUNT=7
```

### Consuming `config.h`

Depend on the generated `cc_library` to include the header:

```python
cc_library(
    name = "mylib",
    srcs = ["mylib.c"],
    deps = ["@my_kconfig//:config"],
)
```

```c
#include "config.h"

#if CONFIG_FOO
/* FOO is enabled */
#endif
```

### Reacting to flags with `config_setting`

The generated repository includes a `settings/` subpackage with
`config_setting` targets for every flag. Bool flags produce a single
target matching `"true"`; int and string flags produce a target matching
their Kconfig default value (named `CONFIG_<NAME>_<value>`).

Use these directly in `select()`:

```python
cc_library(
    name = "mylib",
    srcs = ["mylib.c"],
    deps = select({
        "@my_kconfig//settings:kconfig.CONFIG_FOO": ["//extras:foo_support"],
        "//conditions:default": [],
    }),
)
```

#### Custom values with `kconfig_config_settings`

To match non-default values or multiple values for an int/string flag,
load the generated `settings.bzl` macro and pass an `options` dict.
The `name` parameter prefixes every generated target:

```python
load("@my_kconfig//:settings.bzl", "kconfig_config_settings")

kconfig_config_settings(
    name = "settings",
    options = {
        "CONFIG_COUNT": ["1", "3", "5"],
    },
)
```

This produces `settings.CONFIG_FOO` (bool, auto), `settings.CONFIG_COUNT_1`,
`settings.CONFIG_COUNT_3`, and `settings.CONFIG_COUNT_5`. Flags not listed
in `options` fall back to their Kconfig default. Flags with neither are
simply skipped.

## Providing defaults via `.config`

You can supply a `.config` file to override Kconfig defaults. Pass the
`defaults` attribute when declaring the repository:

```python
kconfig.repo(
    name = "my_kconfig",
    kconfig = "//:Kconfig",
    defaults = "//:.config",
    interpreter = "@python3_host//:python",
)
```

If any Kconfig symbol uses `$(shell,...)` for its default and is not
explicitly set in the `.config` file, the repository rule will fail with
an actionable error message.

## Interactive configuration with `menuconfig`

The `menuconfig` rule launches kconfiglib's terminal UI for interactive
Kconfig editing. Add a target to your `BUILD.bazel`:

```python
load("@rules_kconfig//kconfig:menuconfig.bzl", "menuconfig")

menuconfig(
    name = "menuconfig",
    kconfig = "//:Kconfig",
)
```

Then run:

```bash
bazel run //:menuconfig
```

The TUI reads and writes the `.config` file in your workspace root.

## Build-time values with `settings_labels`

Some Kconfig symbols derive their default from the build environment
using `$(shell,...)` macros — for example, a compiler version obtained
from the active toolchain:

```text
config CLANG_VERSION
    int
    default $(shell,$(srctree)/scripts/clang-version.sh $(CC))
```

These values cannot be resolved at repository-rule time. Use
`settings_labels` to replace a generated flag with a user-provided rule
that supplies the value during the build:

```python
kconfig.repo(
    name = "my_kconfig",
    kconfig = "//:Kconfig",
    interpreter = "@python3_host//:python",
    settings_labels = {
        "//:clang_version": "CONFIG_CLANG_VERSION",
    },
)
```

The label must point to a target that provides `BuildSettingInfo`. Since
Bazel does not allow `build_setting` rules to resolve toolchains
([bazelbuild/bazel#21545](https://github.com/bazelbuild/bazel/issues/21545)),
write a regular rule instead:

```python
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

def _clang_version_impl(ctx):
    cc_toolchain = ctx.toolchains["@rules_cc//cc:toolchain_type"]
    # ... compute version from toolchain ...
    return [BuildSettingInfo(value = version)]

clang_version = rule(
    implementation = _clang_version_impl,
    toolchains = ["@rules_cc//cc:toolchain_type"],
)
```

Settings provided via `settings_labels`:

- appear in the generated `config.h` with the correct value,
- are excluded from `config_setting` generation (they are not flags, so
  `flag_values` cannot reference them),
- cannot be set from the command line,
- are skipped by `kconfig.overrides` transitions — the value always
  comes from the user-provided rule.

See [`examples/settings_labels/`](../../examples/settings_labels/) for a
complete working example including an overrides layer.


## Overriding configuration on external repositories

When a kconfig repository is declared by an external dependency, use
`kconfig.overrides` to overlay your own `.config` without modifying the
external module. If the source repository was itself created with a
`.config`, the overrides are stacked on top of those base values:

```python
kconfig = use_extension("@rules_kconfig//kconfig:extensions.bzl", "kconfig")
kconfig.overrides(
    name = "my_board_config",
    kconfig = "@ext_kconfig//:ext_kconfig",
    config = "//:.config",
    interpreter = "@python3_host//:python",
)
use_repo(kconfig, "my_board_config")
```

Then wrap targets that depend on kconfig flags with the generated
transition rule:

```python
load("@my_board_config//:defs.bzl", "with_kconfig_overrides")

with_kconfig_overrides(
    name = "ext_config_customized",
    actual = "@ext_kconfig//:config",
)
```

Values explicitly set on the command line take precedence over the
overlay.
