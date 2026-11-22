"""What U-Boot's Makefile exports to Kconfig, as this example gives it."""

# U-Boot's tree probes `$(CC)` and `$(LD)` (scripts/Kconfig.include) and
# carries no dummy tools, so the host's compiler answers, for the oracle and
# the generated repository alike; `CC_VERSION_TEXT` and `UBOOTVERSION` only
# reach a comment and the main menu's title. MODULE.bazel repeats this table
# for the `kconfig.repo` tags, as it cannot load this file.
U_BOOT_ENV = {
    "CC": "gcc",
    "CC_VERSION_TEXT": "gcc",
    "LD": "ld",
    "UBOOTVERSION": "2025.10",
}
