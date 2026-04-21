"""Tests for repository_gen manifest building."""

import textwrap
from pathlib import Path

from kconfig.private.kconfig_parser import parse_kconfig
from kconfig.private.repository_gen import KconfigManifest, _build_manifest


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
