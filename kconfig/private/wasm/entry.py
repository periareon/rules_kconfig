"""The entry point of rules_kconfig's WebAssembly backend.

The module built from this file (`//kconfig/private/wasm:kconfig_wasm`) is
CPython with kconfiglib and the generators of this package inside, run by
Bazel's `repository_ctx.execute_wasm`. Nothing inside it can touch the
filesystem, run a command or read the clock; Starlark does all of that. So a
repository is generated in rounds: `run` receives everything Starlark has read
so far, and either produces the repository's files, or answers with what it is
missing. Starlark reads, lists or runs that, and calls again with the larger
request, until the generation completes.

The request and the response are JSON. Text crosses the boundary as Bazel
represents it, one character per byte (Latin-1), so strings are decoded on the
way in and encoded on the way out; see `_text` and `_wire`.

Request::

    {
      "command": "repository" | "overrides",
      "os": "<repository_ctx.os.name>",
      "env": {name: value},                 # repository_ctx.os.environ
      "srctree": "<absolute path>",
      "srctree_realpath": "<absolute path>",
      "kconfig": "<absolute path of the root Kconfig>",
      "files": {path: {"exists": bool, "is_dir": bool, "content": str | null}},
      "dirs": {path: [[name, is_dir], ...] | null},
      "shell": {command: {"stdout": str, "stderr": str, "return_code": int}},
      "uname_release": str | null,
      # "repository":
      "repo_name": str, "defaults": path | null, "config_ws_path": str | null,
      "settings_labels": {name: label}, "settings_options": {name: [value]},
      # "overrides":
      "config": path, "base_config": path | null, "kconfig_repo": str,
      "config_ws_path": str, "settings_labels": {name: label}
    }

Response::

    {"status": "need", "files": [path], "dirs": [path], "shell": [command], "uname_release": bool}
    {"status": "ok", "files": {name: content}, "manifest": {...}}
    {"status": "error", "message": str}
"""

import errno
import fnmatch
import glob
import io
import json
import os
import traceback
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional

import kconfiglib

from kconfig.private import kconfig_parser, overrides_gen, repository_gen

# Marks an attribute kconfiglib did not have before it was patched.
_MISSING = object()

# The outputs of a repository, by file name in the repository.
_REPOSITORY_FILES = {
    "build": "BUILD.bazel",
    "manifest_json": "kconfig.manifest.json",
    "config_h_in": "config.h.in",
    "rendered_config": "rendered.config",
    "settings_bzl": "settings.bzl",
    "settings_build": "settings/BUILD.bazel",
}

_OVERRIDES_FILES = {
    "defs": "defs.bzl",
    "build": "BUILD.bazel",
    "rendered_config": "rendered.config",
}


def _text(value: str) -> str:
    """Decode a string as Bazel passed it: one character per byte of UTF-8."""
    return value.encode("latin-1").decode("utf-8", "surrogateescape")


def _wire(value: str) -> str:
    """Encode text for Bazel: the UTF-8 bytes, one character each."""
    return value.encode("utf-8", "surrogateescape").decode("latin-1")


class Host:
    """What Starlark has provided so far, and what the generation found missing.

    The lookups hand back a placeholder when something is unknown and record
    the request, so that one round discovers as much as it can; a round whose
    requests are not empty is discarded and run again once they are answered.
    """

    def __init__(self, request: Dict[str, Any]) -> None:
        self.files: Dict[str, Optional[Dict[str, Any]]] = {
            _text(path): info for path, info in (request.get("files") or {}).items()
        }
        self.dirs: Dict[str, Optional[List[List[Any]]]] = {
            _text(path): entries
            for path, entries in (request.get("dirs") or {}).items()
        }
        self.shell_results: Dict[str, Optional[Dict[str, Any]]] = {
            _text(command): result
            for command, result in (request.get("shell") or {}).items()
        }
        uname_release = request.get("uname_release")
        self.uname_release = _text(uname_release) if uname_release is not None else None
        # What this round found missing, by kind, in the order it was asked for.
        self.pending_requests: Dict[str, Dict[str, None]] = {
            "files": {},
            "dirs": {},
            "shell": {},
        }
        self.need_uname_release = False

    # -- Lookups -----------------------------------------------------------

    def stat(self, path: str) -> Optional[Dict[str, Any]]:
        """The file's `{exists, is_dir, content}`, or None while unknown."""
        info = self.files.get(path)
        if info is None:
            self.pending_requests["files"][path] = None
        return info

    def exists(self, path: str) -> bool:
        """Whether the file exists; False while unknown."""
        info = self.stat(path)
        return bool(info and info.get("exists"))

    def isdir(self, path: str) -> bool:
        """Whether the path is a directory; False while unknown."""
        info = self.stat(path)
        return bool(info and info.get("exists") and info.get("is_dir"))

    def read(self, path: str) -> str:
        """The text of a file; an empty file while unknown."""
        info = self.stat(path)
        if info is None:
            return ""
        if not info.get("exists"):
            raise FileNotFoundError(errno.ENOENT, os.strerror(errno.ENOENT), path)
        if info.get("is_dir"):
            raise IsADirectoryError(errno.EISDIR, os.strerror(errno.EISDIR), path)
        return _text(info.get("content") or "")

    def listdir(self, path: str, dironly: bool) -> List[str]:
        """The entries of a directory, as `glob` lists them; empty while unknown."""
        if path not in self.dirs:
            self.pending_requests["dirs"][path] = None
            return []
        entries = self.dirs[path]
        if entries is None:
            return []
        return [_text(name) for name, is_dir in entries if not dironly or is_dir]

    def shell(self, command: str) -> Optional[str]:
        """The output of a `$(shell,...)` command as kconfiglib returns it; None while unknown."""
        if command not in self.shell_results:
            self.pending_requests["shell"][command] = None
            return None
        result = self.shell_results[command]
        if result is None:
            return None
        stdout = _text(result.get("stdout") or "")
        return "\n".join(stdout.splitlines()).rstrip("\n").replace("\n", " ")

    def pending(self) -> bool:
        """Whether this round asked for anything it did not have."""
        return self.need_uname_release or any(self.pending_requests.values())

    def needs(self) -> Dict[str, Any]:
        """The `need` response listing what the next round must provide."""
        response: Dict[str, Any] = {"status": "need"}
        for kind, requests in self.pending_requests.items():
            response[kind] = [_wire(item) for item in requests]
        response["uname_release"] = self.need_uname_release
        return response

    # -- The interfaces kconfiglib and the generators use ------------------

    def open(self, filename: str, mode: str = "r", **_kwargs: Any) -> io.StringIO:
        """`open()` over the provided files; reads only, with universal newlines."""
        if "r" not in mode or "+" in mode:
            raise OSError(errno.EROFS, os.strerror(errno.EROFS), filename)
        return io.StringIO(self.read(filename), newline=None)

    def read_text(self, path: Path) -> str:
        """`read` for the generators' `read_text` hook."""
        return self.read(str(path))

    def iglob(self, pathname: str, dironly: bool = False) -> Iterator[str]:
        """`glob.iglob(pathname)` over the provided directories."""
        dirname, basename = os.path.split(pathname)
        if not glob.has_magic(pathname):
            if basename:
                if self.exists(pathname):
                    yield pathname
            elif self.isdir(dirname):
                yield pathname
            return
        if not dirname:
            yield from self._glob1(os.curdir, basename, dironly)
            return
        if dirname != pathname and glob.has_magic(dirname):
            dirs: Iterator[str] = self.iglob(dirname, dironly=True)
        else:
            dirs = iter([dirname])
        for directory in dirs:
            if glob.has_magic(basename):
                names = self._glob1(directory, basename, dironly)
            else:
                names = self._glob0(directory, basename, dironly)
            for name in names:
                yield os.path.join(directory, name)

    def _glob1(self, dirname: str, pattern: str, dironly: bool) -> List[str]:
        names = self.listdir(dirname, dironly)
        if not pattern.startswith("."):
            names = [name for name in names if not name.startswith(".")]
        return fnmatch.filter(names, pattern)

    def _glob0(self, dirname: str, basename: str, _dironly: bool) -> List[str]:
        if basename:
            if self.exists(os.path.join(dirname, basename)):
                return [basename]
        elif self.isdir(dirname):
            return [basename]
        return []


class _OsProxy:
    """`os` as kconfiglib sees it: the environment of the host, the rest unchanged."""

    def __init__(self, environ: Dict[str, str]) -> None:
        self.environ = environ

    def getenv(self, key: str, default: Optional[str] = None) -> Optional[str]:
        """`os.getenv` over the host's environment."""
        return self.environ.get(key, default)

    def __getattr__(self, name: str) -> Any:
        return getattr(os, name)


def _expandvars(environ: Dict[str, str]) -> Any:
    """`os.path.expandvars` over the host's environment, as kconfiglib calls it on strings."""

    def expandvars(path: str) -> str:
        if "$" not in path:
            return path
        result = []
        index = 0
        while index < len(path):
            char = path[index]
            if char != "$":
                result.append(char)
                index += 1
                continue
            rest = path[index + 1 :]
            name = ""
            consumed = 0
            if rest.startswith("{"):
                end = rest.find("}")
                if end > 0:
                    name = rest[1:end]
                    consumed = end + 1
            else:
                while consumed < len(rest) and (
                    rest[consumed].isalnum() or rest[consumed] == "_"
                ):
                    consumed += 1
                name = rest[:consumed]
            if name and name in environ:
                result.append(environ[name])
                index += 1 + consumed
            else:
                result.append(char)
                index += 1
        return "".join(result)

    return expandvars


class _Hooks:
    """Point kconfiglib and the parser at the host for the duration of a call."""

    def __init__(
        self, host: Host, environ: Dict[str, str], srctree_realpath: str
    ) -> None:
        self.host = host
        self.environ = environ
        self.srctree_realpath = srctree_realpath
        self.saved: Dict[str, Any] = {}

    def __enter__(self) -> "_Hooks":
        host = self.host
        patches = {
            "open": host.open,
            "exists": host.exists,
            "iglob": host.iglob,
            "islink": lambda _path: False,
            "realpath": lambda path: (
                self.srctree_realpath if path == self.environ.get("srctree") else path
            ),
            "expandvars": _expandvars(self.environ),
            "os": _OsProxy(self.environ),
        }
        if host.uname_release is not None:
            patches["_UNAME_RELEASE"] = host.uname_release
        for name, value in patches.items():
            # `open` is a builtin kconfiglib has no global for; the module
            # global added here shadows it until `__exit__` removes it.
            self.saved[name] = getattr(kconfiglib, name, _MISSING)
            setattr(kconfiglib, name, value)

        def shell_fn(_kconf: Any, _name: str, command: str) -> str:
            return host.shell(command) or ""

        self.saved["_orig_shell_fn"] = (
            kconfig_parser._orig_shell_fn
        )  # pylint: disable=protected-access
        kconfig_parser._orig_shell_fn = shell_fn  # pylint: disable=protected-access
        return self

    def __exit__(self, *_exc: Any) -> None:
        for name, value in self.saved.items():
            if name == "_orig_shell_fn":
                kconfig_parser._orig_shell_fn = (
                    value  # pylint: disable=protected-access
                )
            elif value is _MISSING:
                delattr(kconfiglib, name)
            else:
                setattr(kconfiglib, name, value)


def _uname_release_needed(host: Host) -> bool:
    """Whether a Kconfig source refers to `$UNAME_RELEASE`, which kconfiglib replaces."""
    if host.uname_release is not None:
        return False
    for info in host.files.values():
        if info and info.get("content") and "$UNAME_RELEASE" in info["content"]:
            return True
    return False


def _optional_path(value: Optional[str]) -> Optional[Path]:
    return Path(_text(value)) if value else None


def _generate(request: Dict[str, Any], host: Host) -> Dict[str, Any]:
    """Run the generator of `request["command"]` and return its files."""
    command = request.get("command")
    srctree = Path(_text(request["srctree"]))
    kconfig = Path(_text(request["kconfig"]))
    settings_labels = {
        _text(name): _text(label)
        for name, label in (request.get("settings_labels") or {}).items()
    }
    if command == "repository":
        outputs = repository_gen.generate(
            kconfig=kconfig,
            srctree=srctree,
            repo_name=_text(request["repo_name"]),
            defaults=_optional_path(request.get("defaults")),
            config_ws_path=(
                _text(request["config_ws_path"])
                if request.get("config_ws_path")
                else None
            ),
            settings_labels=settings_labels,
            settings_options={
                _text(name): [_text(value) for value in values]
                for name, values in (request.get("settings_options") or {}).items()
            },
            read_text=host.read_text,
            chdir=False,
        )
        files = {
            name: getattr(outputs, field) for field, name in _REPOSITORY_FILES.items()
        }
        manifest: Any = outputs.manifest
    elif command == "overrides":
        overrides = overrides_gen.generate(
            kconfig=kconfig,
            srctree=srctree,
            config=Path(_text(request["config"])),
            kconfig_repo=_text(request["kconfig_repo"]),
            config_ws_path=_text(request["config_ws_path"]),
            base_config=_optional_path(request.get("base_config")),
            settings_labels=settings_labels,
            read_text=host.read_text,
            chdir=False,
        )
        files = {
            name: getattr(overrides, field) for field, name in _OVERRIDES_FILES.items()
        }
        manifest = None
    else:
        raise ValueError(f"unknown command {command!r}")

    return {
        "status": "ok",
        "files": {name: _wire(content) for name, content in files.items()},
        "manifest": manifest,
    }


def _error(message: str) -> Dict[str, Any]:
    return {"status": "error", "message": _wire(message)}


def handle(request: Dict[str, Any]) -> Dict[str, Any]:
    """Answer one request: the generated files, what is missing, or an error."""
    host = Host(request)
    environ = {
        _text(name): _text(value) for name, value in (request.get("env") or {}).items()
    }
    environ["srctree"] = _text(request["srctree"])
    srctree_realpath = _text(request.get("srctree_realpath") or request["srctree"])

    response: Dict[str, Any]
    try:
        with _Hooks(host, environ, srctree_realpath):
            response = _generate(request, host)
    except SystemExit as exc:
        response = _error(str(exc.code))
    except Exception:  # pylint: disable=broad-exception-caught
        response = _error(traceback.format_exc())

    # A round that lacked something is discarded, whatever came of it.
    host.need_uname_release = _uname_release_needed(host)
    if host.pending():
        return host.needs()
    return response


def run(payload: bytes) -> bytes:
    """The exported function: a JSON request in, a JSON response out."""
    try:
        response = handle(json.loads(payload.decode("utf-8")))
    except Exception:  # pylint: disable=broad-exception-caught
        response = _error(traceback.format_exc())
    return json.dumps(response).encode("utf-8")
