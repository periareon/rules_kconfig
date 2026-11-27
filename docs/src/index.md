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

The tree is parsed by the Linux kernel's own Kconfig parser, which the
extension downloads for the host (see [Parser](#parser)). `menuconfig` is
the kernel's own `mconf` too, built from the same sources with bison, flex
and ncurses from the registry, launched by a small C++ program built from
source.

## Kconfig versions

Kconfig has no version of its own: the language is whatever the kernel's
`scripts/kconfig` accepts at a release, and that has changed over the years.
`kconfig_version` names the kernel release a tree is written for, and the
tree is then parsed and resolved exactly as that release's `conf` would:

- For a kernel tree, its release: `6.12`, or `6.12.7`.
- For a project with its own copy of the parser, the release the copy was
  synced from.
- A tree that uses `---help---`, `optional` choices or `option` needs a
  version before `6.10`, where the kernel dropped them.

Any `major.minor` or `major.minor.patch` is accepted; the default is `6.17`,
the newest release checked. `rules_kconfig` carries the parser of the
releases where the language changed, and a version is served by the newest
one at or below it:

| `kconfig_version` | parser |
| --- | --- |
| `6.12` and newer | Linux 6.12 |
| `4.19` to `6.11` | Linux 4.19 |

A version below `4.19` is an error. The version is recorded in the
generated repository's manifest, and the `kconfig.overrides` layered on the
repository use the same parser; they take no version of their own.

```python
kconfig.repo(
    name = "my_kconfig",
    kconfig = "@my_tree//:Kconfig",
    kconfig_version = "4.19",
)
```

## Parser

The parser is the Linux kernel's `scripts/kconfig`, of every release in
[Kconfig versions](#kconfig-versions), with this repository's generators,
in one program that a release of `rules_kconfig` ships in two builds. The
`kconfig` extension declares a repository for each, `kconfig_parser_wasm`
and `kconfig_parser_tool_<os>_<cpu>`, the same set on every host, and a
generated repository downloads only the one it runs, through Bazel's
repository cache, the first time. Both builds generate the same repository,
byte for byte.

`bazel fetch --all` and `bazel vendor --all` fetch every build, so an output
base, repository cache or vendor directory filled on one host serves another
offline.

### WebAssembly

On Bazel 9.3 or newer with

```text
common --experimental_repository_ctx_execute_wasm
```

in `.bazelrc`, the repository rules run the parser as a WebAssembly module
with `repository_ctx.execute_wasm`. The module cannot touch the filesystem,
the environment or a shell, so the rules do it on its behalf: they read the
source tree ahead, every directory's listing and every `Kconfig*` file, and
hand it to the module, which asks for what that leaves, `$(shell,...)`
commands, files with other names and the variables a Kconfig names, in a
further round. Everything read is recorded as an input of the repository,
environment variables through `repository_ctx.getenv`, so a repository that
ran no host command is reproducible and Bazel may take it from the repo
contents cache instead of generating it again. With Bazel 10,
`--experimental_repository_ctx_wasm_compilation` compiles the module to JVM
bytecode, which is several times faster than interpreting it.

### Native

Where Bazel cannot run the module, Bazel 7 and 8 or without the flag, the
rules run the same program built natively for the host, with
`repository_ctx.execute` under the same protocol. A release has native builds
for Linux and Windows on x86_64 and aarch64 and for macOS on aarch64.

`--repo_env=RULES_KCONFIG_USE_WASM=0` takes the native build where Bazel
could run the module: interpreted, the module is many times slower than the
native build, which on a large tree is minutes against a second.

### A source checkout

A source checkout of `rules_kconfig` carries no builds. Name one with
`RULES_KCONFIG_WASM` or `RULES_KCONFIG_TOOL` through `--repo_env`: an
absolute path or a URL, for instance the outputs of
`bazel build --config=wasm32 @rules_kconfig//kconfig/private/parser:kconfig_wasm`
and `bazel build @rules_kconfig//kconfig/private/parser:kconfig_tool`.
`RULES_KCONFIG_WASM_INTEGRITY` and `RULES_KCONFIG_TOOL_INTEGRITY` may give
the integrity (`sha256-...`) of a URL.

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
`string` values are quoted (an empty string is `""`), and a symbol that is `n`
is left undefined. So is a symbol the configuration gives no value because its
`depends on` is unmet: its flag still exists, with the falsey default of its
type, but `config.h` leaves it out so that `#ifdef` tells it apart from one
set to `0` or `""`, as the kernel's headers expect.

Some trees' sources expect a `CONFIG_<name>` for every symbol instead.
`write_invisible = True` on `kconfig.repo` writes every symbol, as BusyBox's
`conf` does: one the configuration gives no value goes to `rendered.config`,
in its place, as `# CONFIG_<name> is not set` or with the empty value of its
type (`CONFIG_<name>=""`, `CONFIG_<name>=0`), and `config.h` defines it so.

### Reacting to flags with `config_setting`

The generated repository includes a `settings/` subpackage with
`config_setting` targets for every flag. Bool flags produce two targets:
`CONFIG_<NAME>_Y` (matching `"true"`) and `CONFIG_<NAME>_N` (matching
`"false"`). Int and string flags produce a target matching their Kconfig
default value (named `CONFIG_<NAME>_<value>`; a character a target name may
not hold, such as `:`, is `_` in the name, while the value matched is the
value itself).

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
`$(shell,...)` commands run in an environment. Give the variables the tree
expects with `env`, per repository, so that several configurations of one
tree can come out of a workspace:

```python
kconfig.repo(
    name = "my_kconfig_arm64",
    kconfig = "@my_tree//:Kconfig",
    defaults = "//configs:arm64_defconfig",
    env = {
        "ARCH": "arm64",
        "SRCARCH": "arm64",
    },
)
```

A variable `env` does not name is read from the repository rule's own
environment (`--repo_env`). The variables are recorded in the manifest and
apply to `kconfig.overrides` layered on the repository, and the generated
repository's `kconfig_library` carries them, with the version, for
`menuconfig`. The [upstream example](../../examples/upstream/) generates
repositories this way and checks them against the trees' own `conf`.

### Tools from a toolchain's repository

A tree's `$(shell,...)` macros may run a compiler or linker named by a
variable while the tree is parsed, and what they answer decides which
symbols are visible and selected. A repository rule runs before any
toolchain is resolved, so it cannot ask Bazel for the compiler of a
platform; it can run a binary of a toolchain repository that is already
downloaded. `env_labels` maps such a file to a variable, and its path is
the value:

```python
kconfig.repo(
    name = "my_kconfig_arm64",
    kconfig = "@my_tree//:Kconfig",
    env = {"ARCH": "arm64", "SRCARCH": "arm64"},
    env_labels = {
        "@llvm_toolchain_llvm//:bin/clang": "CC",
        "@llvm_toolchain_llvm//:bin/ld.lld": "LD",
    },
)
```

The binary runs on the host, as a cross compiler does; the paths go into the
manifest for `kconfig.overrides`.

## Interactive configuration with `menuconfig`

The `menuconfig` rule runs `mconf`, the `make menuconfig` terminal UI of
the kernel's `scripts/kconfig`, built from the parser version that serves
the release the tree is written for, so that what it accepts and writes is
what the repository rule reads. Add a target to your `BUILD.bazel`:

```python
load("@rules_kconfig//kconfig:menuconfig.bzl", "menuconfig")

menuconfig(
    name = "menuconfig",
    config = ".config",
    kconfig = "@my_kconfig//:lib",
)
```

Then run it:

```bash
bazel run //:menuconfig
```

The TUI reads and writes the file `config` names, relative to the root
module's workspace. The file must exist there: the launcher resolves the
path on disk and refuses one that leads outside the workspace or to no
file, so `menuconfig` edits a file of your own and nothing else. Everything
else comes from the `kconfig_library`: the files, the release
(`kconfig_version`) and the variables the tree reads (`env`, `env_labels`),
which the `lib` of a generated repository carries as its `kconfig.repo` was
given them.

`mconf` runs over the library's files in the runfiles: the root's directory
there is `$(srctree)` and the working directory, as the repository rule runs
a tree's `$(shell,...)` commands. A tree whose Kconfig files run its own
scripts lists them in the library's `srcs`. Everything is found through the
runfiles and `BUILD_WORKSPACE_DIRECTORY`; no path is absolute or resolved
through symlinks.

A repository generated with `defaults`, and a `kconfig.overrides` over a
`config`, have a `menuconfig` of their own over that file when it is the
root module's: `bazel run @my_kconfig//:menuconfig`. The next build after a
save is under the new configuration, as the repository reads the file.

`mconf` is a curses program over POSIX, so `menuconfig` is for Linux and
macOS. On Windows the target is incompatible: `bazel build //...` skips it,
and `bazel run` reports why.

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
`.config`, the overrides are stacked on top of those base values. The tree
is parsed again as the source repository parsed it, from what its manifest
records: the variables, the `kconfig_version`, the `write_invisible`, and
what the tree's `$(shell,...)` commands answered, so that the overrides are
that configuration with other values, not another host's probes:

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
