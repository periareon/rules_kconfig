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
