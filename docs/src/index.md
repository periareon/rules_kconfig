# rules_kconfig

Bazel rules for parsing [Kconfig](https://www.kernel.org/doc/html/latest/kbuild/kconfig-language.html)
files and generating equivalent Bazel build settings.

A kconfig repository exposes each `config` symbol as a Bazel
[build setting](https://bazel.build/extending/config) flag
(`bool_flag`, `int_flag`, or `string_flag`) whose default matches the
Kconfig-declared default. It also generates a `config.h` header (via
[rules\_cc\_autoconf](https://github.com/periareon/rules_cc_autoconf)) that
reflects the active flag values, so C/C++ code can consume the configuration
with `#include "config.h"`.

## Setup

Add the dependency to your `MODULE.bazel`:

```python
bazel_dep(name = "rules_kconfig", version = "{version}")
```

A Python toolchain is required for parsing. Configure one with
[rules\_python](https://github.com/bazelbuild/rules_python):

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
    config = "//:Kconfig",
    interpreter = "@python_3_12_host//:python",
)
use_repo(kconfig, "my_kconfig")
```

## Generated repository

For a Kconfig file such as:

```
config FOO
    bool "Enable FOO"
    default n

config COUNT
    int "Count"
    default 3
```

The generated repository `@my_kconfig` contains:

| Target | Description |
|--------|-------------|
| `@my_kconfig//:CONFIG_FOO` | `bool_flag` (default `False`) |
| `@my_kconfig//:CONFIG_COUNT` | `int_flag` (default `3`) |
| `@my_kconfig//:config` | `cc_library` providing `config.h` |

## Usage

### Setting flag values

Flags can be set on the command line or in `.bazelrc`:

```
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

Use `config_setting` + `select()` to vary build behavior:

```python
config_setting(
    name = "foo_enabled",
    flag_values = {"@my_kconfig//:CONFIG_FOO": "true"},
)

cc_library(
    name = "mylib",
    srcs = ["mylib.c"],
    deps = select({
        ":foo_enabled": ["//extras:foo_support"],
        "//conditions:default": [],
    }),
)
```
