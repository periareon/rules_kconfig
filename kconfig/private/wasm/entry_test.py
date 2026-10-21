"""Tests of the WebAssembly backend's entry point.

The entry point is plain Python, so it is exercised natively: a small host
answers its requests from the filesystem the way the Starlark loop does,
encoding text as Bazel would, and the files it produces are compared with the
Python backend's generators run directly.
"""

import json
import os
import platform
import subprocess
import textwrap
from pathlib import Path
from typing import Any, Dict, Optional

from kconfig.private import overrides_gen, repository_gen
from kconfig.private.wasm import entry


def _wire(value: str) -> str:
    return value.encode("utf-8").decode("latin-1")


def _text(value: str) -> str:
    return value.encode("latin-1").decode("utf-8")


class Host:  # pylint: disable=too-few-public-methods
    """Answers the module's requests from the filesystem, like Starlark."""

    def __init__(self) -> None:
        self.rounds = 0
        self.first_response: Optional[Dict[str, Any]] = None

    def run(self, request: Dict[str, Any], max_rounds: int = 32) -> Dict[str, Any]:
        """Call `entry.run` until it answers with something other than `need`."""
        for _ in range(max_rounds):
            self.rounds += 1
            response: Dict[str, Any] = json.loads(
                entry.run(json.dumps(request).encode("utf-8"))
            )
            if self.first_response is None:
                self.first_response = response
            if response["status"] != "need":
                return response
            for path in response["files"]:
                request["files"][path] = self._stat(_text(path))
            for path in response["dirs"]:
                request["dirs"][path] = self._listdir(_text(path))
            for command in response["shell"]:
                request["shell"][command] = self._shell(
                    _text(command), _text(request["srctree"])
                )
            if response["uname_release"]:
                request["uname_release"] = _wire(platform.uname().release)
        raise AssertionError("the module did not finish")

    @staticmethod
    def _stat(path: str) -> Dict[str, Any]:
        target = Path(path)
        if not target.exists():
            return {"exists": False, "is_dir": False, "content": None}
        if target.is_dir():
            return {"exists": True, "is_dir": True, "content": None}
        # Bazel reads files as Latin-1: one character per byte.
        return {
            "exists": True,
            "is_dir": False,
            "content": target.read_bytes().decode("latin-1"),
        }

    @staticmethod
    def _listdir(path: str) -> Optional[list[list[Any]]]:
        target = Path(path)
        if not target.is_dir():
            return None
        return [[_wire(entry.name), entry.is_dir()] for entry in target.iterdir()]

    @staticmethod
    def _shell(command: str, srctree: str) -> Dict[str, Any]:
        # The shell kconfiglib's `subprocess.Popen(shell=True)` would use.
        if platform.system() == "Windows":
            argv = ["cmd.exe", "/c", command]
        else:
            argv = ["/bin/sh", "-c", command]
        result = subprocess.run(
            argv,
            cwd=srctree,
            env=dict(os.environ, srctree=srctree),
            capture_output=True,
            check=False,
        )
        return {
            "stdout": result.stdout.decode("latin-1"),
            "stderr": result.stderr.decode("latin-1"),
            "return_code": result.returncode,
        }


def _request(
    command: str, kconfig: Path, srctree: Optional[Path] = None, **fields: Any
) -> Dict[str, Any]:
    srctree = (srctree or kconfig.parent).absolute()
    request: Dict[str, Any] = {
        "command": command,
        "os": "linux",
        "env": {_wire(key): _wire(value) for key, value in os.environ.items()},
        "srctree": _wire(str(srctree)),
        "srctree_realpath": _wire(str(srctree.resolve())),
        "kconfig": _wire(str(kconfig.absolute())),
        "files": {},
        "dirs": {},
        "shell": {},
        "uname_release": None,
    }
    request.update(fields)
    return request


def _decoded_files(response: Dict[str, Any]) -> Dict[str, str]:
    assert response["status"] == "ok", response
    return {name: _text(content) for name, content in response["files"].items()}


def _write_tree(root: Path, files: Dict[str, str]) -> None:
    for name, content in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(content), encoding="utf-8")


TREE = {
    "Kconfig": """\
        mainmenu "Entry test"

        config FOO
            bool "Enable FOO"
            default n

        config COUNT
            int "Count"
            default 3

        config LABEL
            string "Label"
            default "héllo"

        config ADDR
            hex "Address"
            default 0x1000

        menu "Drivers"
        source "drivers/*/Kconfig"
        endmenu

        rsource "extra/Kconfig.extra"
        osource "missing/Kconfig"

        config TAINTED
            string "Tainted"
            default "$(shell,echo from-shell)"
    """,
    "drivers/a/Kconfig": """\
        config DRIVER_A
            tristate "Driver A"
            default y
    """,
    "drivers/b/Kconfig": """\
        config DRIVER_B
            bool "Driver B"
            depends on FOO
            default y
    """,
    "extra/Kconfig.extra": """\
        config EXTRA
            int "Extra"
            default 7
    """,
}


def _expected_repository(root: Path, **kwargs: Any) -> Dict[str, str]:
    outputs = repository_gen.generate(
        kconfig=root / "Kconfig", repo_name="test_kconfig", **kwargs
    )
    return {
        "BUILD.bazel": outputs.build,
        "kconfig.manifest.json": outputs.manifest_json,
        "config.h.in": outputs.config_h_in,
        "rendered.config": outputs.rendered_config,
        "settings.bzl": outputs.settings_bzl,
        "settings/BUILD.bazel": outputs.settings_build,
    }


class TestRepository:
    """`command: repository` produces what `repository_gen` produces."""

    def test_matches_python_backend(self, tmp_path: Path) -> None:
        """A tree with globs, relative and optional sources and a shell macro."""
        _write_tree(tmp_path, TREE)
        host = Host()
        response = host.run(
            _request(
                "repository",
                tmp_path / "Kconfig",
                repo_name="test_kconfig",
                defaults=None,
                config_ws_path=None,
                settings_labels={},
                settings_options={"CONFIG_COUNT": ["1", "3"]},
            )
        )
        files = _decoded_files(response)
        assert files == _expected_repository(
            tmp_path, settings_options={"CONFIG_COUNT": ["1", "3"]}
        )
        assert response["manifest"]["files"] == [
            "Kconfig",
            "drivers/a/Kconfig",
            "drivers/b/Kconfig",
            "extra/Kconfig.extra",
        ]
        assert 'default = "héllo"' in files["BUILD.bazel"]
        # The tainted symbol got the falsey default, with the shell run through the host.
        assert (
            'name = "CONFIG_TAINTED",\n    build_setting_default = "",'
            in files["BUILD.bazel"]
        )

    def test_rounds(self, tmp_path: Path) -> None:
        """The first round asks for the root file; sources follow as they are found."""
        _write_tree(tmp_path, TREE)
        host = Host()
        host.run(
            _request(
                "repository",
                tmp_path / "Kconfig",
                repo_name="test_kconfig",
                defaults=None,
                config_ws_path=None,
                settings_labels={},
                settings_options={},
            )
        )
        assert host.first_response is not None
        assert host.first_response["status"] == "need"
        assert host.first_response["files"] == [_wire(str(tmp_path / "Kconfig"))]
        assert 2 < host.rounds <= 8

    def test_defaults(self, tmp_path: Path) -> None:
        """A `.config` of defaults is read through the host and rendered."""
        _write_tree(tmp_path, TREE)
        (tmp_path / ".config").write_text(
            'CONFIG_FOO=y\nCONFIG_COUNT=42\nCONFIG_TAINTED="set"\n', encoding="utf-8"
        )
        response = Host().run(
            _request(
                "repository",
                tmp_path / "Kconfig",
                repo_name="test_kconfig",
                defaults=_wire(str(tmp_path / ".config")),
                config_ws_path="defaults/.config",
                settings_labels={},
                settings_options={},
            )
        )
        files = _decoded_files(response)
        assert files == _expected_repository(
            tmp_path, defaults=tmp_path / ".config", config_ws_path="defaults/.config"
        )
        assert "CONFIG_COUNT=42" in files["rendered.config"]
        assert 'config = "defaults/.config"' in files["BUILD.bazel"]

    def test_missing_tainted_default_is_an_error(self, tmp_path: Path) -> None:
        """The generator's exit with a message becomes an error response."""
        _write_tree(tmp_path, TREE)
        (tmp_path / ".config").write_text("CONFIG_FOO=y\n", encoding="utf-8")
        response = Host().run(
            _request(
                "repository",
                tmp_path / "Kconfig",
                repo_name="test_kconfig",
                defaults=_wire(str(tmp_path / ".config")),
                config_ws_path=".config",
                settings_labels={},
                settings_options={},
            )
        )
        assert response["status"] == "error"
        assert "CONFIG_TAINTED uses $(shell,...)" in _text(response["message"])

    def test_missing_root_is_an_error(self, tmp_path: Path) -> None:
        """A root Kconfig that does not exist is reported, not retried."""
        response = Host().run(
            _request(
                "repository",
                tmp_path / "Kconfig",
                repo_name="test_kconfig",
                defaults=None,
                config_ws_path=None,
                settings_labels={},
                settings_options={},
            )
        )
        assert response["status"] == "error"
        assert "Kconfig" in _text(response["message"])


class TestOverrides:  # pylint: disable=too-few-public-methods
    """`command: overrides` produces what `overrides_gen` produces."""

    def test_matches_python_backend(self, tmp_path: Path) -> None:
        """Overrides stacked on a base config, the tree read through the host."""
        srcs = tmp_path / "kconfig_srcs"
        _write_tree(srcs, TREE)
        base = repository_gen.generate(kconfig=srcs / "Kconfig", repo_name="ext")
        (tmp_path / "rendered.config").write_text(
            base.rendered_config, encoding="utf-8"
        )
        config = tmp_path / "override.config"
        config.write_text(
            'CONFIG_FOO=y\nCONFIG_COUNT=42\nCONFIG_TAINTED="x"\n', encoding="utf-8"
        )

        response = Host().run(
            _request(
                "overrides",
                srcs / "Kconfig",
                srctree=srcs,
                config=_wire(str(config)),
                base_config=_wire(str(tmp_path / "rendered.config")),
                kconfig_repo="@@ext+",
                config_ws_path="override.config",
                settings_labels={},
            )
        )
        files = _decoded_files(response)
        expected = overrides_gen.generate(
            kconfig=srcs / "Kconfig",
            srctree=srcs,
            config=config,
            kconfig_repo="@@ext+",
            config_ws_path="override.config",
            base_config=tmp_path / "rendered.config",
        )
        assert files == {
            "defs.bzl": expected.defs,
            "BUILD.bazel": expected.build,
            "rendered.config": expected.rendered_config,
        }
        assert '"@@ext+//:CONFIG_COUNT": 42' in files["defs.bzl"]
        assert response["manifest"] is None


def test_unknown_command_is_an_error(tmp_path: Path) -> None:
    """A command the module does not know is an error."""
    response = Host().run(_request("nonsense", tmp_path / "Kconfig"))
    assert response["status"] == "error"
    assert "unknown command" in _text(response["message"])


def test_malformed_payload_is_an_error() -> None:
    """A payload that is not JSON is an error, not a crash."""
    response = json.loads(entry.run(b"not json"))
    assert response["status"] == "error"


class TestWindowsPaths:  # pylint: disable=too-few-public-methods
    """Drive paths, which the module's POSIX interpreter would not treat as absolute."""

    FILES = {
        "C:/tree/Kconfig": 'mainmenu "Win"\n\nconfig A\n\tbool "A"\n\nsource "sub/Kconfig"\n',
        "C:/tree/sub/Kconfig": 'config B\n\tint "B"\n\tdefault 2\n',
    }

    def _serve(self, request: Dict[str, Any]) -> Dict[str, Any]:
        """Answer requests from `FILES`, as Starlark on Windows would, by host path.

        Natively on Windows the entry joins paths with backslashes; they are
        looked up with forward slashes, as Bazel would resolve either.
        """
        for _ in range(10):
            response: Dict[str, Any] = json.loads(
                entry.run(json.dumps(request).encode("utf-8"))
            )
            if response["status"] != "need":
                return response
            for path in response["files"]:
                key = path.replace("\\", "/")
                assert not key.startswith("/"), path
                content = self.FILES.get(key)
                request["files"][path] = {
                    "exists": content is not None,
                    "is_dir": False,
                    "content": content,
                }
            for path in response["dirs"]:
                assert not path.replace("\\", "/").startswith("/"), path
                request["dirs"][path] = None
            assert not response["shell"]
        raise AssertionError("the module did not finish")

    def test_paths_are_returned_in_host_form(self) -> None:
        """Every path asked of Starlark is `C:/...`, never `/C:/...`."""
        request: Dict[str, Any] = {
            "command": "repository",
            "os": "windows 10",
            "env": {},
            "srctree": "C:/tree",
            "srctree_realpath": "C:/tree",
            "kconfig": "C:/tree/Kconfig",
            "files": {},
            "dirs": {},
            "shell": {},
            "uname_release": None,
            "repo_name": "win_kconfig",
            "defaults": None,
            "config_ws_path": None,
            "settings_labels": {},
            "settings_options": {},
        }
        response = self._serve(request)
        assert response["status"] == "ok", response
        assert response["manifest"]["files"] == ["Kconfig", "sub/Kconfig"]
        assert response["manifest"]["root"] == "Kconfig"
        files = _decoded_files(response)
        assert (
            'name = "CONFIG_B",\n    build_setting_default = 2,' in files["BUILD.bazel"]
        )
        assert {path.replace("\\", "/") for path in request["files"]} == set(self.FILES)
