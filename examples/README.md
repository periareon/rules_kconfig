# Examples

Each subdirectory is a standalone Bazel module that demonstrates using `rules_kconfig`.

## simple

A minimal Kconfig tree that shows how to:

1. Declare a `bazel_dep` on `rules_kconfig` and configure the `kconfig` extension.
2. Consume the generated `config.h` header from the kconfig repository.
3. Override kconfig values via command-line flags.

### Layout

- **`MODULE.bazel`** -- Standalone module that depends on `rules_kconfig` and sets up the kconfig extension.
- **`Kconfig`** -- Root Kconfig file with a few options (`CONFIG_FOO`, `CONFIG_COUNT`, `CONFIG_LABEL`).
- **`BUILD.bazel`** -- A `cc_library` that uses `@simple_kconfig//:config.h`.

### Building

```bash
cd examples/simple
bazel build //:lib
```

The examples take `rules_kconfig` from this source checkout, which carries no
build of the parser, so name one through `--repo_env`: `RULES_KCONFIG_TOOL`
as the absolute path of the output of
`bazel build //kconfig/private/parser:kconfig_tool` at the root, or
`RULES_KCONFIG_WASM` as that of `kconfig_wasm` built with `--config=wasm32`,
with `--experimental_repository_ctx_execute_wasm`. With a release of
`rules_kconfig` nothing is needed.

### Overriding kconfig values

Pass flags on the command line or in `.bazelrc`:

```bash
bazel build //:lib \
    --@simple_kconfig//:CONFIG_FOO=true \
    --@simple_kconfig//:CONFIG_COUNT=4
```

The generated `@simple_kconfig//:config.h` will contain:

```c
#define CONFIG_FOO 1
#define CONFIG_COUNT 4
/* #undef CONFIG_LABEL */
```

## kconfig_version

A Kconfig tree written in the grammar of the kernel's parser of 4.19, the
one U-Boot carries: `option modules`, `---help---` and an `optional` choice.
`kconfig.repo` names that release with `kconfig_version = "4.19"`, and the
tree is parsed and resolved as that release's `conf` would; a `cc_test`
checks the `config.h`. Without the version the current kernel's parser
rejects the tree.

## upstream

The Kconfig trees of Linux 6.12, U-Boot v2025.10 and BusyBox 1.37.0, each a
`kconfig.repo` as the tree's own module would declare it, with its
configurations as `kconfig.overrides` layered on it from the tree's
defconfigs, and every one compared with what the tree's own `conf` writes;
the regression tests of the parser against the trees it is meant for. See
[upstream/README.md](upstream/README.md). Linux and macOS only, and the
kernel's tarball is 148 MB.
