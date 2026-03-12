"""Tests for kconfig_parser."""

import textwrap
from pathlib import Path

import pytest

from kconfig.private.kconfig_parser import (
    KconfigSetting,
    collect_settings,
    parse_kconfig,
    read_source_files,
)


def _parse(tmp_path: Path, kconfig_text: str) -> list[KconfigSetting]:
    """Write *kconfig_text* into *tmp_path*/Kconfig and return parsed settings."""
    kconfig_file = tmp_path / "Kconfig"
    kconfig_file.write_text(textwrap.dedent(kconfig_text))

    kconf = parse_kconfig(kconfig_file, tmp_path)
    source_cache = read_source_files(kconf, tmp_path)
    return collect_settings(kconf, source_cache)


class TestBoolType:
    """Parse bool-typed Kconfig symbols."""

    def test_default_y(self, tmp_path: Path) -> None:
        """A bool with ``default y`` produces ``True``."""
        settings = _parse(
            tmp_path,
            """\
            config ENABLED
                bool "Enable"
                default y
        """,
        )

        assert len(settings) == 1
        s = settings[0]
        assert s.name == "ENABLED"
        assert s.rule == "bool_flag"
        assert s.default is True

    def test_default_n(self, tmp_path: Path) -> None:
        """A bool with ``default n`` produces ``False``."""
        settings = _parse(
            tmp_path,
            """\
            config DISABLED
                bool "Disable"
                default n
        """,
        )

        assert len(settings) == 1
        s = settings[0]
        assert s.name == "DISABLED"
        assert s.rule == "bool_flag"
        assert s.default is False


class TestIntType:
    """Parse int-typed Kconfig symbols."""

    def test_default(self, tmp_path: Path) -> None:
        """An int with an explicit default preserves the value."""
        settings = _parse(
            tmp_path,
            """\
            config COUNT
                int "Count"
                default 42
        """,
        )

        assert len(settings) == 1
        s = settings[0]
        assert s.name == "COUNT"
        assert s.rule == "int_flag"
        assert s.default == 42

    def test_zero_default(self, tmp_path: Path) -> None:
        """An int with ``default 0`` is preserved as ``0``."""
        settings = _parse(
            tmp_path,
            """\
            config ZERO
                int "Zero"
                default 0
        """,
        )

        assert settings[0].default == 0


class TestStringType:
    """Parse string-typed Kconfig symbols."""

    def test_default(self, tmp_path: Path) -> None:
        """A string with an explicit default preserves the value."""
        settings = _parse(
            tmp_path,
            """\
            config LABEL
                string "Label"
                default "hello"
        """,
        )

        assert len(settings) == 1
        s = settings[0]
        assert s.name == "LABEL"
        assert s.rule == "string_flag"
        assert s.default == "hello"

    def test_empty_default(self, tmp_path: Path) -> None:
        """A string with ``default ""`` is preserved as ``""``."""
        settings = _parse(
            tmp_path,
            """\
            config EMPTY
                string "Empty"
                default ""
        """,
        )

        assert settings[0].default == ""


class TestHexType:  # pylint: disable=too-few-public-methods
    """Parse hex-typed Kconfig symbols."""

    def test_maps_to_string_flag(self, tmp_path: Path) -> None:
        """Hex symbols are represented as string_flag."""
        settings = _parse(
            tmp_path,
            """\
            config ADDR
                hex "Address"
                default 0xFF
        """,
        )

        assert len(settings) == 1
        s = settings[0]
        assert s.name == "ADDR"
        assert s.rule == "string_flag"
        assert isinstance(s.default, str)


class TestTristateType:  # pylint: disable=too-few-public-methods
    """Parse tristate-typed Kconfig symbols."""

    def test_maps_to_string_flag(self, tmp_path: Path) -> None:
        """Tristate symbols are represented as string_flag."""
        settings = _parse(
            tmp_path,
            """\
            config MODULE
                tristate "Module support"
                default y
        """,
        )

        assert len(settings) == 1
        s = settings[0]
        assert s.name == "MODULE"
        assert s.rule == "string_flag"
        assert s.default == "y"


class TestNoExplicitDefault:
    """Symbols with no ``default`` directive get the falsey value for their type."""

    def test_bool_defaults_to_false(self, tmp_path: Path) -> None:
        """A bare bool defaults to ``False``."""
        settings = _parse(
            tmp_path,
            """\
            config BARE_BOOL
                bool "Bare"
        """,
        )

        assert settings[0].rule == "bool_flag"
        assert settings[0].default is False

    def test_int_defaults_to_zero(self, tmp_path: Path) -> None:
        """A bare int defaults to ``0``."""
        settings = _parse(
            tmp_path,
            """\
            config BARE_INT
                int "Bare"
        """,
        )

        assert settings[0].rule == "int_flag"
        assert settings[0].default == 0

    def test_string_defaults_to_empty(self, tmp_path: Path) -> None:
        """A bare string defaults to ``""``."""
        settings = _parse(
            tmp_path,
            """\
            config BARE_STR
                string "Bare"
        """,
        )

        assert settings[0].rule == "string_flag"
        assert settings[0].default == ""


class TestShellTaintedDefaults:
    """Verify that shell-tainted symbols must be explicitly set when a .config is provided."""

    def test_error_when_shell_tainted_not_in_defaults(self, tmp_path: Path) -> None:
        """A shell-tainted symbol missing from .config causes a hard error."""
        kconfig_file = tmp_path / "Kconfig"
        kconfig_file.write_text(textwrap.dedent("""\
            config ARCH
                string "Architecture"
                default "$(shell,uname -m)"
        """))

        kconf = parse_kconfig(kconfig_file, tmp_path)
        source_cache = read_source_files(kconf, tmp_path)

        dotconfig = tmp_path / ".config"
        dotconfig.write_text("")
        kconf.load_config(str(dotconfig))

        with pytest.raises(SystemExit):
            collect_settings(kconf, source_cache, has_defaults=True)

    def test_ok_when_shell_tainted_set_in_defaults(self, tmp_path: Path) -> None:
        """A shell-tainted symbol explicitly set in .config is accepted."""
        kconfig_file = tmp_path / "Kconfig"
        kconfig_file.write_text(textwrap.dedent("""\
            config ARCH
                string "Architecture"
                default "$(shell,uname -m)"
        """))

        kconf = parse_kconfig(kconfig_file, tmp_path)
        source_cache = read_source_files(kconf, tmp_path)

        dotconfig = tmp_path / ".config"
        dotconfig.write_text('CONFIG_ARCH="x86_64"\n')
        kconf.load_config(str(dotconfig))

        settings = collect_settings(kconf, source_cache, has_defaults=True)

        assert len(settings) == 1
        assert settings[0].name == "ARCH"
        assert settings[0].default == ""


class TestShellTainted:
    """Symbols with ``$(shell,...)`` defaults fall back to the falsey value."""

    def test_falls_back_to_falsey(self, tmp_path: Path) -> None:
        """A string with a shell default gets ``""``."""
        settings = _parse(
            tmp_path,
            """\
            config ARCH
                string "Architecture"
                default "$(shell,uname -m)"
        """,
        )

        assert len(settings) == 1
        s = settings[0]
        assert s.rule == "string_flag"
        assert s.default == ""

    def test_mixed_shell_and_clean(self, tmp_path: Path) -> None:
        """Only the shell-tainted symbol gets the fallback; clean ones are preserved."""
        settings = _parse(
            tmp_path,
            """\
            config CLEAN
                int "Clean"
                default 7

            config TAINTED
                string "Tainted"
                default "$(shell,whoami)"
        """,
        )

        assert len(settings) == 2
        by_name = {s.name: s for s in settings}

        assert by_name["CLEAN"].default == 7
        assert by_name["TAINTED"].default == ""

    def test_bool_shell_tainted(self, tmp_path: Path) -> None:
        """A bool with a shell default falls back to ``False``."""
        settings = _parse(
            tmp_path,
            """\
            config HAS_FEATURE
                bool "Feature"
                default $(shell,test -f /tmp/feature && echo y || echo n)
        """,
        )

        assert settings[0].rule == "bool_flag"
        assert settings[0].default is False


class TestEmptyKconfig:  # pylint: disable=too-few-public-methods
    """An empty Kconfig (no config symbols) produces no settings."""

    def test_no_symbols(self, tmp_path: Path) -> None:
        """A mainmenu-only Kconfig yields an empty list."""
        settings = _parse(
            tmp_path,
            """\
            mainmenu "Empty"
        """,
        )

        assert not settings


class TestSourceDirective:  # pylint: disable=too-few-public-methods
    """Symbols are collected transitively across ``source`` directives."""

    def test_symbols_from_multiple_files(self, tmp_path: Path) -> None:
        """Symbols from sourced files are included alongside root symbols."""
        sub = tmp_path / "sub"
        sub.mkdir()
        (sub / "Kconfig").write_text(textwrap.dedent("""\
            config FROM_SUB
                bool "From sub"
                default y
        """))

        settings = _parse(
            tmp_path,
            """\
            config FROM_ROOT
                int "From root"
                default 5

            source "sub/Kconfig"
        """,
        )

        assert len(settings) == 2
        by_name = {s.name: s for s in settings}

        assert by_name["FROM_ROOT"].rule == "int_flag"
        assert by_name["FROM_ROOT"].default == 5

        assert by_name["FROM_SUB"].rule == "bool_flag"
        assert by_name["FROM_SUB"].default is True
