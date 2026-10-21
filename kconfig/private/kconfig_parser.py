"""Shared Kconfig parsing logic used by repository_gen.py and overrides_gen.py."""

import dataclasses
import logging
import os
import re
import sys
from pathlib import Path
from typing import Any, Callable, Optional, Union

import kconfiglib

_TYPE_MAP = {
    kconfiglib.BOOL: "bool_flag",
    kconfiglib.TRISTATE: "tristate_flag",
    kconfiglib.INT: "int_flag",
    kconfiglib.HEX: "string_flag",
    kconfiglib.STRING: "string_flag",
}

# The Kconfig type names, which `config.h` rendering needs where the flag kind
# is ambiguous (`hex` and `string` are both `string_flag`).
_KCONFIG_TYPE_MAP = {
    kconfiglib.BOOL: "bool",
    kconfiglib.TRISTATE: "tristate",
    kconfiglib.INT: "int",
    kconfiglib.HEX: "hex",
    kconfiglib.STRING: "string",
}

_RULE_TO_KCONFIG_TYPE = {
    "bool_flag": "bool",
    "tristate_flag": "tristate",
    "int_flag": "int",
    "string_flag": "string",
}

# A macro call or variable reference, `$(NAME` with the name captured.
_MACRO_REFERENCE = re.compile(r"\$\(\s*([A-Za-z0-9_-]+)")

_FALSEY_PYTHON_DEFAULTS: dict[str, Union[bool, int, str]] = {
    "bool_flag": False,
    "tristate_flag": "n",
    "int_flag": 0,
    "string_flag": "",
}

_KCONFIG_BLOCK_STARTERS = frozenset(
    {
        "config",
        "menuconfig",
        "menu",
        "endmenu",
        "choice",
        "endchoice",
        "comment",
        "source",
        "rsource",
        "osource",
        "orsource",
        "if",
        "endif",
        "mainmenu",
    }
)


@dataclasses.dataclass(frozen=True)
class KconfigSetting:
    """A parsed Kconfig symbol mapped to its Bazel build setting representation."""

    name: str
    """Symbol name without the CONFIG_ prefix, e.g. ``"FOO"``."""

    rule: str
    """Bazel rule kind: ``"bool_flag"``, ``"int_flag"``, or ``"string_flag"``."""

    default: Union[bool, int, str]
    """Python-native default value for the build setting."""

    kconfig_type: str = ""
    """The Kconfig type: ``"bool"``, ``"tristate"``, ``"int"``, ``"hex"`` or
    ``"string"``. Empty when constructed without one; see :func:`kconfig_type`."""


def kconfig_type(setting: KconfigSetting) -> str:
    """The Kconfig type of a setting, derived from its rule when not recorded."""
    return setting.kconfig_type or _RULE_TO_KCONFIG_TYPE[setting.rule]


# pylint: disable-next=protected-access
_orig_shell_fn: Callable[..., Any] = kconfiglib._shell_fn


def _soft_shell_fn(kconf: kconfiglib.Kconfig, name: str, command: str) -> Any:
    """Wrapper around kconfiglib's `$(shell,...)` that returns a safe fallback on failure."""
    result = _orig_shell_fn(kconf, name, command)
    if result:
        return result

    # Return "n" so unquoted $(shell,...) in bool/tristate defaults tokenizes validly.
    # The actual value is irrelevant — _is_shell_tainted detects these and assigns
    # a type-appropriate fallback.
    return "n"


ReadText = Callable[[Path], str]
"""Reads a file as text; the default reads the filesystem."""


def _read_file(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def parse_kconfig(
    kconfig_path: Path, srctree: Path, *, chdir: bool = True
) -> kconfiglib.Kconfig:
    """Parse a Kconfig file tree and return the kconfiglib object.

    Handles the cwd/srctree dance that kconfiglib requires.
    Shell macros that fail or return empty are replaced with a safe placeholder
    so parsing succeeds on all platforms.

    Args:
        kconfig_path: The root Kconfig file.
        srctree: The directory `source` directives are resolved against.
        chdir: Whether to run the parse from `srctree`, as the C tools do, so
            that `$(shell,...)` commands see it as their working directory.
            The WebAssembly backend has no working directory and passes False.
    """
    prev_dir = os.getcwd() if chdir else None
    if chdir:
        os.chdir(srctree)
    prev_srctree = os.environ.get("srctree")

    # pylint: disable=protected-access
    kconfiglib._shell_fn = _soft_shell_fn
    try:
        os.environ["srctree"] = str(srctree)
        return kconfiglib.Kconfig(
            filename=str(kconfig_path),
            warn=False,
            warn_to_stderr=False,
        )
    finally:
        kconfiglib._shell_fn = _orig_shell_fn
        if prev_srctree is None:
            del os.environ["srctree"]
        else:
            os.environ["srctree"] = prev_srctree
        if prev_dir is not None:
            os.chdir(prev_dir)


def read_source_files(
    kconf: kconfiglib.Kconfig,
    srctree: Path,
    *,
    read_text: Optional[ReadText] = None,
) -> dict[str, list[str]]:
    """Read and cache all Kconfig source files, keyed by kconfiglib filename.

    Args:
        kconf: The parsed configuration.
        srctree: The directory relative filenames are resolved against.
        read_text: How to read a file; defaults to the filesystem.
    """
    reader = read_text or _read_file
    cache: dict[str, list[str]] = {}
    for filename in kconf.kconfig_filenames:
        abs_path = Path(filename)
        if not abs_path.is_absolute():
            abs_path = srctree / filename
        try:
            cache[filename] = reader(abs_path.absolute()).splitlines()
        except OSError:
            logging.warning("Could not read Kconfig source: %s", abs_path)
    return cache


# A preprocessor variable assignment, `NAME = value`, `NAME := value` or
# `NAME += value`, at the start of a line.
_VARIABLE_ASSIGNMENT = re.compile(r"^\s*([A-Za-z0-9_-]+)\s*(?::=|\+=|=)(.*)$")


def _tainted_variables(source_cache: dict[str, list[str]]) -> set[str]:
    """The preprocessor variables whose value comes, possibly indirectly, from `$(shell,...)`.

    A symbol can take a host-dependent default without naming `$(shell,...)`
    itself, through `VAR := $(shell,...)` and `default $(VAR)`; such symbols
    are treated like direct uses. The sources are scanned rather than
    kconfiglib's variables, which hold `:=` values already expanded.
    """
    assigned: dict[str, set[str]] = {}
    for lines in source_cache.values():
        for line in lines:
            match = _VARIABLE_ASSIGNMENT.match(line)
            if match:
                assigned.setdefault(match.group(1), set()).update(
                    _MACRO_REFERENCE.findall(match.group(2))
                )

    tainted: set[str] = set()
    changed = True
    while changed:
        changed = False
        for name, references in assigned.items():
            if name not in tainted and ("shell" in references or references & tainted):
                tainted.add(name)
                changed = True
    return tainted


def _is_shell_tainted(
    sym: kconfiglib.Symbol,
    source_cache: dict[str, list[str]],
    tainted_variables: set[str] | None = None,
) -> bool:
    """Check whether a definition of sym uses $(shell,...), directly or through a variable."""
    tainted_variables = tainted_variables or set()
    for node in sym.nodes:
        lines = source_cache.get(node.filename)
        if lines is None:
            continue

        start = node.linenr - 1
        end = start + 1
        while end < len(lines):
            line = lines[end]
            stripped = line.lstrip()
            if not stripped or stripped.startswith("#"):
                end += 1
                continue
            if line[0] not in (" ", "\t"):
                first_word = stripped.split()[0]
                if first_word in _KCONFIG_BLOCK_STARTERS:
                    break
            end += 1

        for i in range(start, min(end, len(lines))):
            references = set(_MACRO_REFERENCE.findall(lines[i]))
            if "shell" in references or references & tainted_variables:
                return True

    return False


def python_default(sym: kconfiglib.Symbol, rule: str) -> Union[bool, int, str]:
    """Convert a symbol's resolved Kconfig default to a Python-native value."""
    if rule == "bool_flag":
        return bool(sym.str_value == "y")
    if rule == "tristate_flag":
        return str(sym.str_value)
    if rule == "int_flag":
        try:
            return int(sym.str_value)
        except ValueError:
            return 0
    return str(sym.str_value)


def collect_settings(
    kconf: kconfiglib.Kconfig,
    source_cache: dict[str, list[str]],
    *,
    has_defaults: bool = False,
    labeled_symbols: set[str] | None = None,
) -> list[KconfigSetting]:
    """Parse a Kconfig object into a list of :class:`KconfigSetting` entries.

    Symbols whose definitions contain ``$(shell,...)`` macros receive the
    falsey default for their type to avoid host-dependent values.

    When *has_defaults* is ``True``, the caller has already loaded a
    ``.config`` via ``kconf.load_config``.  Shell-tainted symbols that
    were **not** explicitly set in that file cause a hard error, unless
    they appear in *labeled_symbols* (symbols handled by ``settings_labels``).
    """
    if labeled_symbols is None:
        labeled_symbols = set()
    errors: list[str] = []
    result: list[KconfigSetting] = []
    tainted_variables = _tainted_variables(source_cache)
    for sym in kconf.unique_defined_syms:
        rule = _TYPE_MAP.get(sym.orig_type)
        if not rule:
            logging.debug("Skipping symbol %s (type %s)", sym.name, sym.orig_type)
            continue

        shell_tainted = _is_shell_tainted(sym, source_cache, tainted_variables)

        if (
            shell_tainted
            and has_defaults
            and sym.user_value is None
            and f"CONFIG_{sym.name}" not in labeled_symbols
        ):
            errors.append(
                "CONFIG_{name} uses $(shell,...) for its default but is not "
                "explicitly set in the defaults file. Run menuconfig or add "
                "CONFIG_{name}=<value> to your .config file.".format(name=sym.name)
            )

        if shell_tainted:
            default = _FALSEY_PYTHON_DEFAULTS[rule]
            logging.info(
                "CONFIG_%s uses $(shell,...); defaulting to %s", sym.name, default
            )
        else:
            default = python_default(sym, rule)

        result.append(
            KconfigSetting(
                name=sym.name,
                rule=rule,
                default=default,
                kconfig_type=_KCONFIG_TYPE_MAP[sym.orig_type],
            )
        )

    if errors:
        msg = "Defaults file is missing required symbols:\n" + "\n".join(
            "  - " + e for e in errors
        )
        # Exits with the message on stderr and status 1 when run as a tool;
        # the WebAssembly backend catches it and reports the message.
        sys.exit(msg)

    return result
