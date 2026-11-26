# Upstream trees: Linux, U-Boot and BusyBox

The Kconfig trees of Linux 6.12, U-Boot v2025.10 and BusyBox 1.37.0, fetched
at those releases, as regression tests of the parser against the trees it is
meant for, laid out as a tree's own module and its consumers would: one
`kconfig.repo` per tree, the tree with every symbol at its default
(`make alldefconfig`; BusyBox's `make defconfig`), and each configuration a
consumer builds as a `kconfig.overrides` layered on it from a defconfig. The
base is generated with the parser of the tree's `kconfig_version` (Linux the
default `6.12`; U-Boot `4.19`, the kernel release its `scripts/kconfig` is a
copy of; BusyBox `4.19` too, see below), and an overrides repository parses
the tree again as the base did, from what its manifest records: the tree's
path and variables, the version, what the `$(shell,...)` probes answered and
`write_invisible`. For every case the tree's own `scripts/kconfig/conf`,
built from the tree (with the `bison` and `flex` modules where the tree does
not ship the generated parser), writes the `.config` of `make <defconfig>`
or `make alldefconfig` with the same variables (`conf_config.sh`, run with
`run_binary`), and a `diff_test` compares the two whole, but for the heading
`conf` writes (see `defs.bzl`). A `cc_test` per board includes the generated
`config.h`; for an overrides repository that is the base's `config.h` under
the overrides' transition.

The example is about the `kconfig` module extension, not the trees: nothing
of Linux, U-Boot or BusyBox is built but `conf`, the ten or so C files of
`scripts/kconfig`, as the oracle; the `cc_test`s compile a file of this
example that includes `config.h`.

| Case | Repository | Compared with |
| --- | --- | --- |
| `//linux:x86_64_alldefconfig` | `@linux_x86` (base) | `make alldefconfig` |
| `//linux:x86_64_defconfig` | `@linux_x86_64` (overrides) | `make x86_64_defconfig` |
| `//linux:arm64_defconfig` | `@linux_arm64` (base, with `defaults`) | `make ARCH=arm64 defconfig` |
| `//uboot:alldefconfig` | `@u_boot` (base) | `make alldefconfig` |
| `//uboot:qemu_arm64_defconfig` | `@u_boot_qemu_arm64` (overrides) | `make qemu_arm64_defconfig` |
| `//uboot:qemu_x86_64_defconfig` | `@u_boot_qemu_x86_64` (overrides) | `make qemu-x86_64_defconfig` |
| `//busybox:defconfig` | `@busybox` (base) | `make defconfig` |
| `//busybox:nommu_defconfig` | `@busybox_nommu` (overrides) | `make TEST_nommu_defconfig` |
| `//busybox:freebsd_defconfig` | `@busybox_freebsd` (overrides) | `make freebsd_defconfig` |

Linux has two bases because the architecture is the tree's variables
(`ARCH`, `SRCARCH`), which the tree reads before any `.config` and an
overrides cannot change; `@linux_arm64` takes its defconfig as `defaults`,
the other way to a configuration.

## The trees' variables

Linux and U-Boot read variables their Makefiles export: Linux `ARCH`,
`SRCARCH`, `CC`, `LD`, `KERNELVERSION` and more, U-Boot `CC`, `LD` and
`UBOOTVERSION`; BusyBox's tree names none.
Each `kconfig.repo` names its own with `env`, which is how two architectures
of the kernel come out of one workspace; the overrides layered on a
repository take them from its manifest. Linux is configured with its
`scripts/dummy-tools`, the stand-in toolchain the kernel keeps for
`make CROSS_COMPILE=scripts/dummy-tools/`, so that the compiler probes answer
the same on every host; they are given as files with `env_labels`, the way a
downloaded toolchain's compiler would be. U-Boot has none, and the host's
`gcc` answers for the oracle and the repository alike.

The values a toolchain knows without running anything come from the
toolchain Bazel resolves for the build: `//linux:cc_path` is a
`make_variable_setting` of `$(CC)`, and `settings_labels` makes it
`CONFIG_CC_VERSION_TEXT` of `@linux_x86`, which the `config.h` test of the
`@linux_x86_64` overrides checks: a labeled setting is left to the base. A `cc_library` or `rust_library` sees nothing but the header.

## The defconfigs

U-Boot's and BusyBox's cases take the defconfigs straight from the tree
(BusyBox's `configs/` are whole `.config` files of older releases; the
symbols they name that the tree no longer has are passed over, as `conf`
passes over them). The Linux
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

## BusyBox

BusyBox's `scripts/kconfig` is the kernel's of 2.6.2x, older than any parser
rules_kconfig builds, so its cases name `4.19`, the oldest; its tree uses
nothing the 4.19 grammar lacks (no `option`, no `$(...)`, every choice with a
default), and the `diff_test`s are what shows the two resolve it the same.
Three things about the tree are BusyBox's own, and the example meets each:

- The `Config.in` files but the root are generated. `make` runs
  `scripts/gen_build_files.sh`, which writes each directory's `Config.in`
  from its `Config.src` and the `//config:` lines of its sources; the
  archive carries only those, so the `http_archive` runs the script when
  it extracts (`patch_cmds`).
- Its `conf` is the old one: `-d` and `-D <file>` for `make defconfig` and
  `make <board>_defconfig`, and `.config` written to the working directory,
  with no `KCONFIG_CONFIG`. `conf_config` runs it in a scratch directory
  with `srctree` naming the tree, as `make O=` would (`old_conf`).
- Its `conf` writes every symbol, the invisible too (`confdata.c`: "we want
  to see all syms"), as its sources expect `ENABLE_<name>` and
  `CONFIG_<name>` for each. `write_invisible = True` on the `kconfig.repo`
  writes them the same way, each in its place: `# CONFIG_X is not set`, or
  the empty value of the type (`CONFIG_TELINIT_PATH=""`,
  `CONFIG_FEATURE_KILL_DELAY=0`), which the `config.h` test checks; the
  overrides on it do the same, from its manifest.

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
