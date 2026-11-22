"""The versions of the Kconfig parser rules_kconfig builds, and what a consumer's names.

Kconfig has no version of its own: the parser is `scripts/kconfig` of the
Linux kernel, and the only name for a state of it is the kernel release that
carried it. Projects that copy the parser, U-Boot, barebox and BusyBox, keep
the release they synced from. So `kconfig_version` names a kernel release,
any `major.minor` or `major.minor.patch`: the release the tree is from, or
the one its copy of the parser is.

The grammar and the resolution rules have changed with releases, so
rules_kconfig builds the kernel's parser at the releases where they did, and
a version is served by the newest build at or below it (`parser_version`):
the tree is then parsed and resolved as that release's `conf` would. The
builds, and the changes that bound them, are `PARSER_VERSIONS`; a version
below the oldest is an error.
"""

# The kernel releases the parser is built at, newest first, with the changes
# that make each the right one for the versions down to the next:
#
# - `6.12`: the current grammar. 6.10 dropped `option` (for `modules` on its
#   own and environment variables) and `optional` choices; 6.11 reworked
#   choices and gave an unset `int` or `hex` the value 0 rather than "".
# - `4.19`: the grammar U-Boot's `scripts/kconfig` is a copy of (barebox's and
#   BusyBox's are near): `---help---`, `optional`, `option env=`,
#   `option modules`, `option defconfig_list`, unquoted prompts and sources.
#   4.18 brought the `$(...)` preprocessor; nothing older is built.
#
# Releases between 4.19 and 6.10 kept the grammar of 4.19 but changed the
# resolution at the edges (where `imply` reads the dependencies, choice
# defaults) and what `conf` writes (`# end of` comments); a tree from one of
# them is served by `4.19`, and a build at one of them is the thing to add if
# the differential test of `examples/upstream` ever shows a difference.
PARSER_VERSIONS = [
    "6.12",
    "4.19",
]

# The newest kernel release whose `scripts/kconfig` has been compared with
# the newest build's and found to resolve the same, and so the default. From
# 6.12 to 6.17 the grammar only lost `bool "prompt"` as a way to prompt a
# choice (`prompt` remains) and three warnings became errors (a `menuconfig`
# without a prompt, a blank or repeated help text); the values and what
# `conf` writes did not change. A newer release is accepted and served by the
# newest build, unchecked; when a release changes the language, it joins
# `PARSER_VERSIONS` and this moves up to it.
LATEST_KCONFIG_VERSION = "6.17"

DEFAULT_KCONFIG_VERSION = LATEST_KCONFIG_VERSION

def version_id(version):
    """A version as it appears in names: `6.12` as `6_12`.

    Args:
        version: One of `PARSER_VERSIONS`.

    Returns:
        str: The version with `_` for `.`, for the names of repositories,
            targets and environment variables.
    """
    return version.replace(".", "_")

def _parse(version, what):
    parts = version.split(".")
    if len(parts) not in (2, 3) or not all([part.isdigit() for part in parts]):
        fail("{} names kconfig_version `{}`, which is not a kernel release (`6.12`, `6.12.7`)".format(what, version))
    return tuple([int(part) for part in parts[:2]])

def parser_version(version, what = "kconfig_version"):
    """The build that serves a version: the newest at or below it.

    Args:
        version: A kernel release, `major.minor` or `major.minor.patch`.
        what: What named it, for the error.

    Returns:
        str: One of `PARSER_VERSIONS`.
    """
    wanted = _parse(version, what)
    for candidate in PARSER_VERSIONS:
        if _parse(candidate, "PARSER_VERSIONS") <= wanted:
            return candidate
    fail("{} names kconfig_version `{}`, older than the oldest parser rules_kconfig builds, `{}`".format(
        what,
        version,
        PARSER_VERSIONS[-1],
    ))
