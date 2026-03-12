"""Shared Kconfig parsing logic used by repository_gen.py and overrides_gen.py."""

import dataclasses
import logging
import os
import sys
from pathlib import Path
from typing import Union

import kconfiglib  # type: ignore[import-untyped]

_TYPE_MAP = {
    kconfiglib.BOOL: "bool_flag",
    kconfiglib.TRISTATE: "string_flag",
    kconfiglib.INT: "int_flag",
    kconfiglib.HEX: "string_flag",
    kconfiglib.STRING: "string_flag",
}

_FALSEY_PYTHON_DEFAULTS: dict[str, Union[bool, int, str]] = {
    "bool_flag": False,
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

log = logging.getLogger(__name__)


@dataclasses.dataclass(frozen=True)
class KconfigSetting:
    """A parsed Kconfig symbol mapped to its Bazel build setting representation."""

    name: str
    """Symbol name without the CONFIG_ prefix, e.g. ``"FOO"``."""

    rule: str
    """Bazel rule kind: ``"bool_flag"``, ``"int_flag"``, or ``"string_flag"``."""

    default: Union[bool, int, str]
    """Python-native default value for the build setting."""


def parse_kconfig(kconfig_path: Path, srctree: Path) -> kconfiglib.Kconfig:
    """Parse a Kconfig file tree and return the kconfiglib object.

    Handles the cwd/srctree dance that kconfiglib requires.
    """
    prev_dir = os.getcwd()
    os.chdir(srctree)
    try:
        os.environ["srctree"] = str(srctree)
        return kconfiglib.Kconfig(
            filename=str(kconfig_path),
            warn=False,
            warn_to_stderr=False,
        )
    finally:
        os.chdir(prev_dir)


def read_source_files(kconf: kconfiglib.Kconfig, srctree: Path) -> dict[str, list[str]]:
    """Read and cache all Kconfig source files, keyed by kconfiglib filename."""
    cache: dict[str, list[str]] = {}
    for filename in kconf.kconfig_filenames:
        abs_path = Path(filename)
        if not abs_path.is_absolute():
            abs_path = srctree / filename
        try:
            cache[filename] = (
                abs_path.absolute().read_text(encoding="utf-8").splitlines()
            )
        except OSError:
            log.warning("Could not read Kconfig source: %s", abs_path)
    return cache


def _is_shell_tainted(
    sym: kconfiglib.Symbol, source_cache: dict[str, list[str]]
) -> bool:
    """Check whether any definition of sym directly contains $(shell,...) macros."""
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

        if any("$(shell," in lines[i] for i in range(start, min(end, len(lines)))):
            return True

    return False


def python_default(sym: kconfiglib.Symbol, rule: str) -> Union[bool, int, str]:
    """Convert a symbol's resolved Kconfig default to a Python-native value."""
    if rule == "bool_flag":
        return bool(sym.str_value == "y")
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
) -> list[KconfigSetting]:
    """Parse a Kconfig object into a list of :class:`KconfigSetting` entries.

    Symbols whose definitions contain ``$(shell,...)`` macros receive the
    falsey default for their type to avoid host-dependent values.

    When *has_defaults* is ``True``, the caller has already loaded a
    ``.config`` via ``kconf.load_config``.  Shell-tainted symbols that
    were **not** explicitly set in that file cause a hard error.
    """
    errors: list[str] = []
    result: list[KconfigSetting] = []
    for sym in kconf.unique_defined_syms:
        rule = _TYPE_MAP.get(sym.orig_type)
        if not rule:
            log.debug("Skipping symbol %s (type %s)", sym.name, sym.orig_type)
            continue

        shell_tainted = _is_shell_tainted(sym, source_cache)

        if shell_tainted and has_defaults and sym.user_value is None:
            errors.append(
                "CONFIG_{name} uses $(shell,...) for its default but is not "
                "explicitly set in the defaults file. Run menuconfig or add "
                "CONFIG_{name}=<value> to your .config file.".format(name=sym.name)
            )

        if shell_tainted:
            default = _FALSEY_PYTHON_DEFAULTS[rule]
            log.info("CONFIG_%s uses $(shell,...); defaulting to %s", sym.name, default)
        else:
            default = python_default(sym, rule)

        result.append(KconfigSetting(name=sym.name, rule=rule, default=default))

    if errors:
        msg = "Defaults file is missing required symbols:\n" + "\n".join(
            "  - " + e for e in errors
        )
        print(msg, file=sys.stderr)
        sys.exit(1)

    return result
