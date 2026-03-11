"""Tests for repository_gen."""

import os
import textwrap
from pathlib import Path

import kconfiglib
import pytest

from kconfig.private.repository_gen import (
    KconfigSetting,
    collect_settings,
    read_source_files,
)


def _parse(tmp_path: Path, kconfig_text: str) -> list[KconfigSetting]:
    """Write *kconfig_text* into *tmp_path*/Kconfig and return parsed settings."""
    kconfig_file = tmp_path / "Kconfig"
    kconfig_file.write_text(textwrap.dedent(kconfig_text))

    prev_dir = os.getcwd()
    os.chdir(tmp_path)
    try:
        os.environ["srctree"] = str(tmp_path)
        kconf = kconfiglib.Kconfig(
            filename=str(kconfig_file),
            warn=False,
            warn_to_stderr=False,
        )
    finally:
        os.chdir(prev_dir)

    source_cache = read_source_files(kconf, tmp_path)
    return collect_settings(kconf, source_cache)


class TestBoolType:
    def test_default_y(self, tmp_path: Path) -> None:
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
    def test_default(self, tmp_path: Path) -> None:
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
    def test_default(self, tmp_path: Path) -> None:
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
        settings = _parse(
            tmp_path,
            """\
            config EMPTY
                string "Empty"
                default ""
        """,
        )

        assert settings[0].default == ""


class TestHexType:
    def test_maps_to_string_flag(self, tmp_path: Path) -> None:
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


class TestTristateType:
    def test_maps_to_string_flag(self, tmp_path: Path) -> None:
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
    def test_bool_defaults_to_false(self, tmp_path: Path) -> None:
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
        settings = _parse(
            tmp_path,
            """\
            config BARE_STR
                string "Bare"
        """,
        )

        assert settings[0].rule == "string_flag"
        assert settings[0].default == ""


class TestShellTainted:
    def test_falls_back_to_falsey(self, tmp_path: Path) -> None:
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


class TestEmptyKconfig:
    def test_no_symbols(self, tmp_path: Path) -> None:
        settings = _parse(
            tmp_path,
            """\
            mainmenu "Empty"
        """,
        )

        assert settings == []


class TestSourceDirective:
    def test_symbols_from_multiple_files(self, tmp_path: Path) -> None:
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
