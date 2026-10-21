"""Tests for overrides_gen."""

import textwrap
from pathlib import Path

from kconfig.private import overrides_gen, repository_gen

KCONFIG = """\
    config FOO
        bool "Foo"
        default n

    config COUNT
        int "Count"
        default 3

    config NAME
        string "Name"
        default "123"
"""


def _tree(tmp_path: Path) -> Path:
    srcs = tmp_path / "kconfig_srcs"
    srcs.mkdir()
    (srcs / "Kconfig").write_text(textwrap.dedent(KCONFIG), encoding="utf-8")
    return srcs


def _generate(srcs: Path, config: Path, base_config: Path | None) -> str:
    return overrides_gen.generate(
        kconfig=srcs / "Kconfig",
        srctree=srcs,
        config=config,
        kconfig_repo="@@ext",
        config_ws_path="override.config",
        base_config=base_config,
    ).defs


class TestStacking:
    """Overrides stack on the base configuration of the source repository."""

    def test_unmentioned_symbols_keep_base_values(self, tmp_path: Path) -> None:
        """A symbol the override file does not name is not overridden."""
        srcs = _tree(tmp_path)
        base = tmp_path / "base.config"
        base.write_text('CONFIG_COUNT=42\nCONFIG_NAME="base"\n', encoding="utf-8")
        override = tmp_path / "override.config"
        override.write_text("CONFIG_FOO=y\n", encoding="utf-8")

        defs = _generate(srcs, override, base)

        overrides = defs[
            defs.index("_OVERRIDES = {") : defs.index("_kconfig_overrides_transition")
        ]
        assert '"@@ext//:CONFIG_FOO": True' in overrides
        assert "CONFIG_COUNT" not in overrides
        assert "CONFIG_NAME" not in overrides
        originals = defs[
            defs.index("_ORIGINAL_DEFAULTS = {") : defs.index("_OVERRIDES = {")
        ]
        assert '"@@ext//:CONFIG_COUNT": 42' in originals
        assert '"@@ext//:CONFIG_NAME": "base"' in originals

    def test_without_base_config(self, tmp_path: Path) -> None:
        """Without a base, originals are the Kconfig defaults and overrides the differences."""
        srcs = _tree(tmp_path)
        override = tmp_path / "override.config"
        override.write_text("CONFIG_COUNT=7\n", encoding="utf-8")

        defs = _generate(srcs, override, None)

        overrides = defs[
            defs.index("_OVERRIDES = {") : defs.index("_kconfig_overrides_transition")
        ]
        assert overrides.strip() == '_OVERRIDES = {\n    "@@ext//:CONFIG_COUNT": 7,\n}'

    def test_rendered_config_merges(self, tmp_path: Path) -> None:
        """The rendered configuration holds the base values with the overrides applied."""
        srcs = _tree(tmp_path)
        base = tmp_path / "base.config"
        base.write_text("CONFIG_COUNT=42\n", encoding="utf-8")
        override = tmp_path / "override.config"
        override.write_text("CONFIG_FOO=y\n", encoding="utf-8")

        outputs = overrides_gen.generate(
            kconfig=srcs / "Kconfig",
            srctree=srcs,
            config=override,
            kconfig_repo="@@ext",
            config_ws_path="override.config",
            base_config=base,
        )

        assert "CONFIG_FOO=y" in outputs.rendered_config
        assert "CONFIG_COUNT=42" in outputs.rendered_config


def test_repository_records_kconfig_types(tmp_path: Path) -> None:
    """The generated `kconfig_autoconf` knows each symbol's Kconfig type."""
    srcs = _tree(tmp_path)
    (srcs / "Kconfig").write_text(
        textwrap.dedent(KCONFIG) + textwrap.dedent("""\
            config ADDR
                hex "Address"
                default 0x10

            config MOD
                tristate "Module"
            """),
        encoding="utf-8",
    )
    outputs = repository_gen.generate(kconfig=srcs / "Kconfig", repo_name="t")
    assert '"CONFIG_NAME": "string",' in outputs.build
    assert '"CONFIG_ADDR": "hex",' in outputs.build
    assert '"CONFIG_MOD": "tristate",' in outputs.build
    assert '"CONFIG_COUNT": "int",' in outputs.build
    assert "#undef CONFIG_MOD\n#undef CONFIG_MOD_MODULE\n" in outputs.config_h_in
    assert "#undef CONFIG_NAME_MODULE" not in outputs.config_h_in
