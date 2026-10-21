"""The WebAssembly backend of the kconfig repository rules.

A release of rules_kconfig publishes `kconfig.wasm`: CPython with kconfiglib and
this package's generators inside, built by `//kconfig/private/wasm:kconfig_wasm`
with `rules_venv`'s `py_wasm_module`. The release bakes the module's URL and
integrity into `wasm/module.bzl`, the `kconfig` extension downloads it into the
`kconfig_wasm` repository, and when Bazel exposes `repository_ctx.execute_wasm`
(`--experimental_repository_ctx_execute_wasm`, Bazel 9.3 or newer) the
repository rules generate repositories with it; no Python interpreter is needed.

The module cannot read files, list directories or run commands, so a repository
is generated in rounds: the module answers with what it is missing, this code
reads, lists or runs it (recording the files as inputs of the repository, as the
Python backend's `watch` calls do), and calls again. See
`kconfig/private/wasm/entry.py` for the protocol.
"""

load("//kconfig/private/wasm:module.bzl", "MODULE_INTEGRITY", "MODULE_URL")

# A module to use instead of the release's: the absolute path of a file, or a
# URL (`http://`, `https://`, `file://`), for instance the output of
# `bazel build @rules_kconfig//kconfig/private/wasm:kconfig_wasm`. A source
# checkout of rules_kconfig has no module of its own and needs this.
MODULE_ENV = "RULES_KCONFIG_WASM"

# The expected integrity (`sha256-<base64>`) of a module named by a URL in
# `RULES_KCONFIG_WASM`; optional.
MODULE_INTEGRITY_ENV = "RULES_KCONFIG_WASM_INTEGRITY"

_EXPORT = "run"
_MEMORY_LIMIT = 512 * 1024 * 1024
_TIMEOUT = 600
_MAX_ROUNDS = 256

def _getenv(ctx, name):
    if hasattr(ctx, "getenv"):
        return ctx.getenv(name)
    return ctx.os.environ.get(name)

def _is_url(location):
    return location.startswith(("http://", "https://", "file://"))

def wasm_module_location(module_ctx):
    """Where the module comes from, for the `kconfig_wasm` repository.

    Args:
        module_ctx: The module extension's context.

    Returns:
        struct: `url` and `integrity`, or `path`; None when this checkout has
            no module and none is named by `RULES_KCONFIG_WASM`.
    """
    override = _getenv(module_ctx, MODULE_ENV)
    if override:
        if _is_url(override):
            return struct(
                url = override,
                integrity = _getenv(module_ctx, MODULE_INTEGRITY_ENV) or "",
                path = None,
            )
        return struct(url = None, integrity = "", path = override)
    if MODULE_INTEGRITY:
        return struct(url = MODULE_URL, integrity = MODULE_INTEGRITY, path = None)
    return None

def _kconfig_wasm_repository_impl(repository_ctx):
    if repository_ctx.attr.path:
        path = repository_ctx.path(repository_ctx.attr.path)
        repository_ctx.watch(path)
        if not path.exists:
            fail("{} names `{}`, which does not exist".format(MODULE_ENV, repository_ctx.attr.path))
        repository_ctx.symlink(path, "kconfig.wasm")
    else:
        repository_ctx.download(
            url = repository_ctx.attr.url,
            output = "kconfig.wasm",
            integrity = repository_ctx.attr.integrity,
        )
    repository_ctx.file("BUILD.bazel", """exports_files(["kconfig.wasm"])
""")

kconfig_wasm_repository = repository_rule(
    doc = "Holds the WebAssembly backend, downloaded from a release or taken from a local build.",
    implementation = _kconfig_wasm_repository_impl,
    attrs = {
        "integrity": attr.string(
            doc = "The expected integrity of the module at `url`; may be empty.",
        ),
        "path": attr.string(
            doc = "The absolute path of a module, used instead of `url`.",
        ),
        "url": attr.string(
            doc = "Where to download the module from.",
        ),
    },
)

def select_backend(repository_ctx):
    """Decide how to generate a repository.

    The WebAssembly module is used whenever Bazel can run it (Bazel 9.3 or
    newer with `--experimental_repository_ctx_execute_wasm`) and there is one
    (a release carries one; `RULES_KCONFIG_WASM` names one for a source
    checkout); the `interpreter` is then ignored. Otherwise the Python
    interpreter generates the repository, and must be given.

    Args:
        repository_ctx: The repository rule's context. Its rule has the
            `wasm_module` attribute (the label of the module, or None) and
            the `interpreter` attribute.

    Returns:
        struct: `name` is `"wasm"` or `"python"`; `module` is the path of the
            module for `"wasm"`.
    """
    if hasattr(repository_ctx, "execute_wasm") and repository_ctx.attr.wasm_module:
        return struct(
            name = "wasm",
            module = repository_ctx.path(repository_ctx.attr.wasm_module),
        )
    if not repository_ctx.attr.interpreter:
        fail(
            "{} has no Python `interpreter`, and the WebAssembly backend cannot be used: ".format(repository_ctx.name) +
            ("Bazel does not expose `execute_wasm` (Bazel 9.3 or newer with " +
             "`--experimental_repository_ctx_execute_wasm`)" if not hasattr(repository_ctx, "execute_wasm") else "this checkout of rules_kconfig is not a release and carries no module (build one with " +
                                                                                                                 "`bazel build @rules_kconfig//kconfig/private/wasm:kconfig_wasm` and name it with " + MODULE_ENV + ")") +
            ". Set `interpreter` to a Python 3 interpreter target, e.g. `@python_3_14_host//:python`.",
        )
    return struct(name = "python", module = None)

def new_request(repository_ctx, command, kconfig, srctree):
    """The request of a first round.

    Args:
        repository_ctx: The repository rule's context.
        command: `"repository"` or `"overrides"`.
        kconfig: The path of the root Kconfig file.
        srctree: The path of the source tree.

    Returns:
        dict: The request, to be completed with the command's fields.
    """
    return {
        "command": command,
        "dirs": {},
        "env": dict(repository_ctx.os.environ),
        "files": {},
        "kconfig": str(kconfig),
        "os": repository_ctx.os.name,
        "shell": {},
        "srctree": str(srctree),
        "srctree_realpath": str(srctree.realpath),
        "uname_release": None,
    }

def _is_windows(repository_ctx):
    return repository_ctx.os.name.lower().startswith("windows")

def _stat(repository_ctx, path):
    """What the module asks of a file: whether it exists, and its content."""
    target = repository_ctx.path(path)
    if not target.exists:
        repository_ctx.watch(target)
        return {"content": None, "exists": False, "is_dir": False}
    if target.is_dir:
        repository_ctx.watch(target)
        return {"content": None, "exists": True, "is_dir": True}
    return {"content": repository_ctx.read(target), "exists": True, "is_dir": False}

def _listdir(repository_ctx, path):
    """The entries of a directory, or None when there is no such directory."""
    target = repository_ctx.path(path)
    if not target.exists or not target.is_dir:
        repository_ctx.watch(target)
        return None
    return [[entry.basename, entry.is_dir] for entry in target.readdir()]

def _shell(repository_ctx, command, srctree):
    """Run a `$(shell,...)` command the way the Python backend's kconfiglib does."""
    if _is_windows(repository_ctx):
        argv = ["cmd.exe", "/c", command]
    else:
        argv = ["/bin/sh", "-c", command]
    result = repository_ctx.execute(
        argv,
        timeout = _TIMEOUT,
        environment = {"srctree": str(srctree)},
        quiet = True,
        working_directory = str(srctree),
    )
    return {
        "return_code": result.return_code,
        "stderr": result.stderr,
        "stdout": result.stdout,
    }

def _uname_release(repository_ctx):
    if _is_windows(repository_ctx):
        return ""
    result = repository_ctx.execute(["uname", "-r"], quiet = True)
    if result.return_code != 0:
        return ""
    return result.stdout.strip()

def run_module(repository_ctx, module_path, request):
    """Run the module until it produces the repository's files.

    Args:
        repository_ctx: The repository rule's context.
        module_path: The path of the module.
        request: A request from `new_request`, completed for its command.

    Returns:
        dict: The module's `ok` response: `files` maps repository paths to
            contents, `manifest` is the repository's manifest where there is one.
    """
    module = repository_ctx.load_wasm(module_path)
    srctree = repository_ctx.path(request["srctree"])

    for _ in range(_MAX_ROUNDS):
        result = repository_ctx.execute_wasm(
            module,
            _EXPORT,
            input = json.encode(request),
            timeout = _TIMEOUT,
            memory_limit = _MEMORY_LIMIT,
        )
        if result.return_code != 0:
            fail("The kconfig module failed (code {}): {}\n{}".format(
                result.return_code,
                result.error_message,
                result.output,
            ))
        response = json.decode(result.output)
        status = response.get("status")
        if status == "ok":
            return response
        if status == "error":
            fail("Failed to generate the kconfig repository:\n{}".format(response.get("message")))
        if status != "need":
            fail("The kconfig module answered with an unknown status: {}".format(status))

        for path in response.get("files", []):
            request["files"][path] = _stat(repository_ctx, path)
        for path in response.get("dirs", []):
            request["dirs"][path] = _listdir(repository_ctx, path)
        for command in response.get("shell", []):
            request["shell"][command] = _shell(repository_ctx, command, srctree)
        if response.get("uname_release"):
            request["uname_release"] = _uname_release(repository_ctx)

    fail("The kconfig module did not finish within {} rounds".format(_MAX_ROUNDS))

def write_files(repository_ctx, files):
    """Write the module's output files into the repository.

    Args:
        repository_ctx: The repository rule's context.
        files: `path` to content, from an `ok` response.
    """
    for path, content in files.items():
        repository_ctx.file(path, content, executable = False, legacy_utf8 = False)
