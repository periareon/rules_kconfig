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

Then register a kconfig repository via the module extension:

```python
kconfig = use_extension("@rules_kconfig//kconfig:extensions.bzl", "kconfig")
kconfig.repo(
    name = "my_kconfig",
    kconfig = "//:Kconfig",
)
use_repo(kconfig, "my_kconfig")
```

The Kconfig tree is parsed by the Linux kernel's Kconfig parser, in one of two
builds a release publishes; see [Backends](#backends). No Python is needed,
except for `menuconfig`, which runs
[kconfiglib](https://github.com/ulfalizer/Kconfiglib)'s interface on a
[rules_python](https://github.com/bazelbuild/rules_python) toolchain.

## Backends

A kconfig repository is generated from a parsed Kconfig tree by the parser of
`kconfig/private/parser`, which a release ships as a WebAssembly module and as
a native build per platform.

### WebAssembly

Each release of `rules_kconfig` publishes `kconfig.wasm`: the Linux kernel's
Kconfig parser (`scripts/kconfig`, GPL-2.0) and the generators, written in
Rust, built for `wasm32-wasip1` by `//kconfig/private/parser` with
`rules_rust` and the wasi-sdk toolchain of `tools/wasi_sdk`; the module
imports nothing from its host. The
kernel sources are fetched when the module is built, from a pinned tag, and
patched for the syntax kconfiglib accepts and the kernel's no longer does
(`---help---`, `optional` choices, `option`, unquoted prompts and sources) and
to report an error instead of exiting; see `kconfig/private/parser/kernel`.
Where the kernel's parser and kconfiglib disagree on a value, the module
answers as kconfiglib does.
The release bakes the module's URL and integrity into the
rules, and the `kconfig` extension downloads it through Bazel's repository
cache the first time a repository is generated with it. On Bazel 9.3 or newer
with

```text
common --experimental_repository_ctx_execute_wasm
```

in `.bazelrc`, the repository rules run it with `repository_ctx.execute_wasm`
and no Python interpreter is needed. The module cannot touch the filesystem,
the environment or a shell, so the rules do it on its behalf: they read the
source tree ahead, every directory's listing and every `Kconfig*` file, and
hand it to the module, which asks for what that leaves, `$(shell,...)`
commands, files with other names and the variables a Kconfig names, in a
further round. Everything read is recorded as an input of the
repository, environment variables through `repository_ctx.getenv`, so a
repository that ran no host command is reproducible and Bazel may take it from
the repo contents cache instead of generating it again. With Bazel 10,
`--experimental_repository_ctx_wasm_compilation` compiles the module to JVM
bytecode, which is several times faster than interpreting it.

### Native

Each release also attaches the same program built natively,
`kconfig_tool-<os>-<cpu>`, for Linux and Windows on x86_64 and aarch64 and for
macOS on aarch64, built on a runner of each platform with its host toolchain.
Where Bazel cannot run the module, the rules run the build for the host with
`repository_ctx.execute`, under the same round protocol with the request and
the response in files, so that a repository comes out byte for byte the same
whichever build generated it. This is the backend for Bazel 7 and 8.

### Choosing

The WebAssembly module is used whenever Bazel can run it and there is one;
otherwise the native build, where there is one for the host; a release has
both, a source checkout of `rules_kconfig` has neither. Where neither can be
used the repository rule fails with an error that says why. There is no
setting to choose; the Bazel flag and the host are the switch.

For a source checkout, `RULES_KCONFIG_WASM` and `RULES_KCONFIG_TOOL` (through
`--repo_env`) name a module and a native build to use, an absolute path or a
URL, for instance the outputs of
`bazel build --config=wasm32 @rules_kconfig//kconfig/private/parser:kconfig_wasm`
and `bazel build @rules_kconfig//kconfig/private/parser:kconfig_tool`;
`RULES_KCONFIG_WASM_INTEGRITY` and `RULES_KCONFIG_TOOL_INTEGRITY` may give the
integrity (`sha256-...`) of a URL.

Both builds produce the same repository, byte for byte, and the same one
kconfiglib produced before the parser replaced it:
`//kconfig/private/parser:parser_test` runs the native build under the
module's protocol against golden files generated by kconfiglib, and CI
generates the example repositories with both builds.

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
| `@my_kconfig//settings.CONFIG_FOO_Y`   | `config_setting` matching `CONFIG_FOO = true`  |
| `@my_kconfig//settings.CONFIG_FOO_N`   | `config_setting` matching `CONFIG_FOO = false` |
| `@my_kconfig//settings.CONFIG_COUNT_3` | `config_setting` matching `CONFIG_COUNT = 3`   |

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

The header follows the Kconfig tools' `autoconf.h`: `bool` and `tristate`
symbols set to `y` define `CONFIG_<name>` as `1`, a `tristate` set to `m`
defines `CONFIG_<name>_MODULE` instead, `int` and `hex` values are unquoted,
`string` values are quoted, and a symbol that is `n` or an empty string is left
undefined.

### Reacting to flags with `config_setting`

The generated repository includes a `settings/` subpackage with
`config_setting` targets for every flag. Bool flags produce two targets:
`CONFIG_<NAME>_Y` (matching `"true"`) and `CONFIG_<NAME>_N` (matching
`"false"`). Int and string flags produce a target matching their Kconfig
default value (named `CONFIG_<NAME>_<value>`).

Use these directly in `select()`:

```python
cc_library(
    name = "mylib",
    srcs = ["mylib.c"],
    deps = select({
        "@my_kconfig//settings:kconfig.CONFIG_FOO_Y": ["//extras:foo_support"],
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
)
```

A symbol whose definition runs `$(shell,...)` would take a value from the
host that generates the repository. Where a `.config` can set the symbol (it
has a prompt whose condition holds) the repository rule does not bake the
host's value in: without a defaults file the flag's default is the falsey one
of its type, and with one the symbol must be set there, or the rule fails
with an error listing the symbols to add. Where no `.config` can set the
symbol, as it has no prompt or its dependencies are off (the kernel's
`CC_IS_GCC` and the compiler probes behind it), it takes the value the
Kconfig tools calculate, the one `rendered.config` shows; `settings_labels`
replaces such a symbol with a build-time value.

## The tree's environment variables

A Kconfig tree may read variables with `$(NAME)` or `option env`, and its
`$(shell,...)` commands run in an environment. The kernel's tree reads
`ARCH`, `SRCARCH`, `CC`, `LD` and the others its Makefile exports. Give them
with `env`, per repository, so that several configurations of one tree can
come out of a workspace:

```python
kconfig.repo(
    name = "linux_arm64",
    kconfig = "@linux//:Kconfig",
    defaults = "//configs:arm64_defconfig",
    env = {
        "ARCH": "arm64",
        "SRCARCH": "arm64",
        "CC": "scripts/dummy-tools/gcc",
        "LD": "scripts/dummy-tools/ld",
    },
)
```

A variable `env` does not name is read from the repository rule's own
environment (`--repo_env`). The variables are recorded in the manifest and
apply to `kconfig.overrides` layered on the repository. The
[upstream example](../../examples/upstream/) generates repositories from
the Linux and U-Boot trees this way and checks them against the trees' own
`conf`.

### Tools from a toolchain's repository

The kernel's `$(cc-option,...)`, `$(as-instr,...)` and `$(success,...)`
probes run `$(CC)`, `$(LD)` or `$(RUSTC)` while the tree is parsed, and what
they answer decides which symbols are visible and selected. A repository
rule runs before any toolchain is resolved, so it cannot ask Bazel for the
compiler of a platform; it can run a binary of a toolchain repository that
is already downloaded. `env_labels` maps such a file to a variable, and its
path is the value:

```python
kconfig.repo(
    name = "linux_arm64",
    kconfig = "@linux//:Kconfig",
    env = {"ARCH": "arm64", "SRCARCH": "arm64"},
    env_labels = {
        "@llvm_toolchain_llvm//:bin/clang": "CC",
        "@llvm_toolchain_llvm//:bin/ld.lld": "LD",
    },
)
```

The binary runs on the host, as a cross compiler does; the paths go into the
manifest for `kconfig.overrides`. Where no toolchain is wanted at that point,
the kernel's `scripts/dummy-tools` answer every probe the same way, which is
what the upstream example does.

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

For a value a toolchain already knows, a "Make" variable such as `$(CC)`,
`$(C_COMPILER)` or rules_rust's `$(RUSTC)`, `make_variable_setting` is that
rule, with the toolchain targets in its `toolchains` attribute:

```python
load("@rules_kconfig//kconfig:defs.bzl", "make_variable_setting")

make_variable_setting(
    name = "cc_path",
    expression = "$(CC)",
    toolchains = ["@bazel_tools//tools/cpp:current_cc_toolchain"],
)

make_variable_setting(
    name = "cc_is_clang",
    equals = "clang",
    expression = "$(C_COMPILER)",
    toolchains = ["@bazel_tools//tools/cpp:current_cc_toolchain"],
    type = "bool",
)
```

Named in `settings_labels`, these give `CONFIG_CC_VERSION_TEXT` or
`CONFIG_CC_IS_CLANG` the toolchain Bazel resolved for the build, in
`config.h` and `select()`, which an ordinary `cc_library` or `rust_library`
then consumes. A symbol other symbols depend on is a different matter: the
dependencies were resolved when the repository was generated, with the
variables of `env` and `env_labels`, and a build-time value does not
re-evaluate them.

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
