# Upstream trees: Linux and U-Boot

The Kconfig trees of Linux 6.12 and U-Boot v2025.10, fetched at those
releases, as regression tests of the parser against the trees it is meant
for. For each case a repository is generated with `kconfig.repo`, with the
parser of the tree's `kconfig_version` (Linux the default `6.12`; U-Boot
`4.19`, the kernel release its `scripts/kconfig` is a copy of), and the
tree's own `scripts/kconfig/conf`, built from the tree with the `bison` and
`flex` modules, writes the `.config` of `make <defconfig>` or
`make alldefconfig` with the same variables; a `diff_test` compares the two
whole, but for the heading `conf` writes (see `defs.bzl`). A `cc_test` per
board includes the generated `config.h`.

| Case | Repository | Compared with |
| --- | --- | --- |
| `//linux:x86_64_defconfig` | `@linux_x86_64` | `make x86_64_defconfig` |
| `//linux:arm64_defconfig` | `@linux_arm64` | `make ARCH=arm64 defconfig` |
| `//linux:x86_64_alldefconfig` | `@linux_x86_64_alldefconfig` | `make alldefconfig` |
| `//uboot:qemu_arm64_defconfig` | `@u_boot_qemu_arm64` | `make qemu_arm64_defconfig` |
| `//uboot:qemu_x86_64_defconfig` | `@u_boot_qemu_x86_64` | `make qemu-x86_64_defconfig` |
| `//uboot:alldefconfig` | `@u_boot_alldefconfig` | `make alldefconfig` |

## The trees' variables

Both trees read variables their Makefiles export: Linux `ARCH`, `SRCARCH`,
`CC`, `LD`, `KERNELVERSION` and more, U-Boot `CC`, `LD` and `UBOOTVERSION`.
Each `kconfig.repo` names its own with `env`, which is how two architectures
of the kernel come out of one workspace. Linux is configured with its
`scripts/dummy-tools`, the stand-in toolchain the kernel keeps for
`make CROSS_COMPILE=scripts/dummy-tools/`, so that the compiler probes answer
the same on every host; they are given as files with `env_labels`, the way a
downloaded toolchain's compiler would be. U-Boot has none, and the host's
`gcc` answers for the oracle and the repository alike.

The values a toolchain knows without running anything come from the
toolchain Bazel resolves for the build: `//linux:cc_path` is a
`make_variable_setting` of `$(CC)`, and `settings_labels` makes it
`CONFIG_CC_VERSION_TEXT` of `@linux_x86_64`, which the `config.h` test
checks. A `cc_library` or `rust_library` sees nothing but the header.

## The defconfigs

U-Boot's cases take the boards' defconfigs straight from the tree. The Linux
cases take copies under `linux/configs`, the kernel's own defconfigs with a
few lines added at the end: the symbols `rules_kconfig` asks a defaults file
to decide, because they have a prompt and their definition runs the compiler
(`STACKPROTECTOR`, `STACKPROTECTOR_STRONG`, `CFI_CLANG`, `GCC_PLUGINS`, and
`X86_X32_ABI` on x86 or the `DEBUG_INFO_COMPRESSED` choice and
`DEBUG_INFO_SPLIT` on arm64). Without them the repository rule stops with an
error naming them. The values are the ones the kernel calculates, so the
configurations are the kernel's. A symbol no `.config` can set, as it has no
prompt or its dependencies are off, takes the value the kernel calculates
without being listed.

## Running

```bash
cd examples/upstream
bazel test //... --repo_env=RULES_KCONFIG_TOOL=/path/to/kconfig_tool
```

The trees are downloaded once into Bazel's repository cache (the kernel's
tarball is 148 MB). This example runs on Linux and macOS; the oracle runs the
trees' shell scripts.

## Known difference: U-Boot's `.config` strings

U-Boot's kconfig reads and writes string values verbatim, while the kernel's
unescapes them when reading and escapes `"` and `\` when writing. A
`.config` line such as

```text
CONFIG_AUTOBOOT_PROMPT="Enter password \"a\" in %d seconds to stop autoboot\n"
```

keeps its `\n` through U-Boot's `conf` and loses the backslash through the
parser here, which is the kernel's of 4.19 as released; the verbatim strings
are U-Boot's own change to its copy of `confdata.c`. `sandbox_defconfig` has
such a line and is not among the cases for that reason; 97 of the 1477
defconfigs of v2025.10 have one, nearly all `CONFIG_AUTOBOOT_PROMPT` or
`CONFIG_IDENT_STRING`.
