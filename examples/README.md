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
build of the parser, so name one: `RULES_KCONFIG_WASM` (with
`--experimental_repository_ctx_execute_wasm`) or `RULES_KCONFIG_TOOL`, as
absolute paths through `--repo_env`, for instance the outputs of
`bazel build --config=wasm32 //kconfig/private/parser:kconfig_wasm` and
`bazel build //kconfig/private/parser:kconfig_tool` at the root. With a
release of `rules_kconfig` nothing is needed.

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

## upstream

The Kconfig trees of Linux 6.12 and U-Boot v2025.10, each generated into
repositories for a few defconfigs and compared with what the tree's own
`conf` writes for them; the regression tests of the parser against the trees
it is meant for. See [upstream/README.md](upstream/README.md). Linux and
macOS only, and the kernel's tarball is 148 MB.
