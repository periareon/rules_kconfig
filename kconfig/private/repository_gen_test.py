"""Tests for repository_gen manifest building and settings rendering."""

import textwrap
from pathlib import Path

from kconfig.private.kconfig_parser import KconfigSetting, parse_kconfig
from kconfig.private.repository_gen import (
    KconfigManifest,
    _build_manifest,
    _render_settings_bzl,
)


def _manifest(
    tmp_path: Path, kconfig_text: str, *, has_defaults: bool = False
) -> KconfigManifest:
    """Write kconfig_text to tmp_path/Kconfig and return the built manifest."""
    kconfig_file = tmp_path / "Kconfig"
    kconfig_file.write_text(textwrap.dedent(kconfig_text))
    kconf = parse_kconfig(kconfig_file, tmp_path)
    return _build_manifest(kconf, tmp_path, has_defaults=has_defaults)


class TestBuildManifest:
    """Tests for _build_manifest."""

    def test_single_file(self, tmp_path: Path) -> None:
        """A single Kconfig produces a manifest with one entry."""
        manifest = _manifest(
            tmp_path,
            """\
            config FOO
                bool "Foo"
        """,
        )
        assert manifest["root"] == "Kconfig"
        assert manifest["files"] == ["Kconfig"]
        assert "config" not in manifest

    def test_files_are_sorted(self, tmp_path: Path) -> None:
        """Files from source directives appear in sorted order."""
        sub_b = tmp_path / "b"
        sub_b.mkdir()
        (sub_b / "Kconfig").write_text("config B\n    bool\n")
        sub_a = tmp_path / "a"
        sub_a.mkdir()
        (sub_a / "Kconfig").write_text("config A\n    bool\n")

        manifest = _manifest(
            tmp_path,
            """\
            source "b/Kconfig"
            source "a/Kconfig"
        """,
        )
        assert manifest["files"] == ["Kconfig", "a/Kconfig", "b/Kconfig"]

    def test_diamond_source_is_deduplicated(self, tmp_path: Path) -> None:
        """A shared file sourced from two sub-Kconfigs appears only once."""
        (tmp_path / "shared.kconfig").write_text("config SHARED\n    bool\n")
        (tmp_path / "a").mkdir()
        (tmp_path / "a" / "Kconfig").write_text('source "shared.kconfig"\n')
        (tmp_path / "b").mkdir()
        (tmp_path / "b" / "Kconfig").write_text('source "shared.kconfig"\n')

        manifest = _manifest(
            tmp_path,
            """\
            source "a/Kconfig"
            source "b/Kconfig"
        """,
        )
        assert manifest["files"] == [
            "Kconfig",
            "a/Kconfig",
            "b/Kconfig",
            "shared.kconfig",
        ]

    def test_root_is_entry_file(self, tmp_path: Path) -> None:
        """Root is always the entry-point Kconfig, not the first sorted."""
        sub = tmp_path / "a"
        sub.mkdir()
        (sub / "Kconfig").write_text("config A\n    bool\n")

        manifest = _manifest(
            tmp_path,
            """\
            source "a/Kconfig"
        """,
        )
        assert manifest["root"] == "Kconfig"

    def test_has_defaults_adds_config_key(self, tmp_path: Path) -> None:
        """has_defaults=True includes the config key."""
        manifest = _manifest(
            tmp_path,
            """\
            config FOO
                bool "Foo"
        """,
            has_defaults=True,
        )
        assert manifest["config"] == "rendered.config"

    def test_has_defaults_false_no_config_key(self, tmp_path: Path) -> None:
        """has_defaults=False omits the config key."""
        manifest = _manifest(
            tmp_path,
            """\
            config FOO
                bool "Foo"
        """,
            has_defaults=False,
        )
        assert "config" not in manifest

    def test_subdirectory_paths_are_posix(self, tmp_path: Path) -> None:
        """Nested paths use forward slashes."""
        sub = tmp_path / "a" / "b"
        sub.mkdir(parents=True)
        (sub / "Kconfig").write_text("config NESTED\n    bool\n")

        manifest = _manifest(
            tmp_path,
            """\
            source "a/b/Kconfig"
        """,
        )
        assert "a/b/Kconfig" in manifest["files"]

    def test_shell_default_does_not_break_parsing(self, tmp_path: Path) -> None:
        """A bool with an invalid $(shell,...) default still produces a valid manifest."""
        manifest = _manifest(
            tmp_path,
            """\
            config FOO
                bool "Enable FOO"
                default $(shell, exit 1)
                help
                Example boolean option.

            config COUNT
                int "Count"
                default $(shell, exit 1)
                help
                Example integer option.

            config LABEL
                string "Label"
                default $(shell, exit 1)
                help
                Example string option.

        """,
        )
        assert manifest["root"] == "Kconfig"
        assert manifest["files"] == ["Kconfig"]


class TestRenderSettingsBzl:
    """Tests for _render_settings_bzl config_setting target naming."""

    def test_bool_flag_produces_y_and_n_suffixes(self) -> None:
        """Bool flags emit config_setting targets with _Y and _N suffixes."""
        settings = [KconfigSetting(name="FOO", rule="bool_flag", default=True)]
        output = _render_settings_bzl(settings)
        assert 'name = name + "." + flag.name + "_Y"' in output
        assert 'name = name + "." + flag.name + "_N"' in output

    def test_bool_flag_no_unsuffixed_target(self) -> None:
        """Bool flags must not produce an unsuffixed config_setting target."""
        settings = [KconfigSetting(name="FOO", rule="bool_flag", default=False)]
        output = _render_settings_bzl(settings)
        for line in output.splitlines():
            if "name = name" in line and "flag.name" in line:
                assert "_Y" in line or "_N" in line or "str(value)" in line

    def test_int_flag_uses_value_suffix(self) -> None:
        """Int flags emit config_setting targets with _<value> suffixes."""
        settings = [KconfigSetting(name="COUNT", rule="int_flag", default=42)]
        output = _render_settings_bzl(settings)
        assert 'name = name + "." + flag.name + "_" + str(value)' in output

    def test_bool_and_int_same_stem_no_collision(self) -> None:
        """A bool CONFIG_FOO_1 and int CONFIG_FOO cannot produce the same target name."""
        settings = [
            KconfigSetting(name="FOO_1", rule="bool_flag", default=True),
            KconfigSetting(name="FOO", rule="int_flag", default=1),
        ]
        output = _render_settings_bzl(settings)
        assert 'Label("//:CONFIG_FOO_1")' in output
        assert 'Label("//:CONFIG_FOO")' in output
        assert "_Y" in output
        assert "_N" in output

    def test_labels_excluded_from_rendered_flags(self) -> None:
        """Settings covered by settings_labels do not appear in flag lists."""
        settings = [
            KconfigSetting(name="LABELED", rule="bool_flag", default=True),
            KconfigSetting(name="UNLABELED", rule="int_flag", default=5),
        ]
        output = _render_settings_bzl(
            settings,
            settings_labels={"CONFIG_LABELED": "//some:label"},
        )
        assert "CONFIG_LABELED" not in output
        assert 'Label("//:CONFIG_UNLABELED")' in output
