"""What the kernel's Makefile exports to Kconfig, as this example gives it."""

# Linux configures with `scripts/dummy-tools` standing in for the toolchain
# (`make CROSS_COMPILE=scripts/dummy-tools/`), which answers every compiler
# and linker probe the same way on every host, so that the repositories come
# out the same everywhere. MODULE.bazel repeats this table for the
# `kconfig.repo` tags, as it cannot load this file, with the tools as labels
# (`env_labels`) where the oracle, running in the tree, names them by path.
LINUX_ENV = {
    "BINDGEN": "no-bindgen",
    "CC": "scripts/dummy-tools/gcc",
    "CC_VERSION_TEXT": "gcc (scripts/dummy-tools/gcc)",
    "KERNELVERSION": "6.12.0",
    "LD": "scripts/dummy-tools/ld",
    "NM": "scripts/dummy-tools/nm",
    "OBJCOPY": "scripts/dummy-tools/objcopy",
    "PAHOLE": "scripts/dummy-tools/pahole",
    "RUSTC": "no-rustc",
}

def linux_env(arch):
    """The variables for one architecture.

    Args:
        arch: `ARCH`, which is also `SRCARCH` for the architectures here.

    Returns:
        dict: The variables.
    """
    return LINUX_ENV | {"ARCH": arch, "SRCARCH": arch}
