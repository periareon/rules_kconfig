"""The parser backends of the kconfig repository rules.

A release of rules_kconfig publishes the parser (kconfig/private/parser: the
Linux kernel's Kconfig parser and this repository's generators, in Rust)
twice: as `kconfig.wasm`, which Bazel 9.3 or newer runs through
`repository_ctx.execute_wasm` (`--experimental_repository_ctx_execute_wasm`),
and as a native build per platform, `kconfig_tool-<os>-<cpu>`, which any
Bazel runs through `repository_ctx.execute`. Both are the same program and
generate the same repository. The release bakes their URLs and integrities
into `parser/module.bzl`, the `kconfig` extension downloads what the host can
use into the `kconfig_parser` repository, and the repository rules take the
module where Bazel can run it and the native build otherwise, or where
`RULES_KCONFIG_USE_WASM=0` asks for it.

The parser cannot read files, list directories, read the environment or run
commands, so a repository is generated in rounds: this code reads the source
tree ahead (every directory's listing and every `Kconfig*` file) and the
variables the parser reads of its own accord, the parser answers with
whatever else it is missing, this code reads or runs it, and calls again.
Each round reruns the whole generation, so the first request carries as much
as can be known. Everything read is recorded as an input of the repository,
environment variables through `getenv`. See `kconfig/private/parser/src/lib.rs` for the protocol.
"""

load(
    "//kconfig/private/parser:module.bzl",
    "MODULE_INTEGRITY",
    "MODULE_URL",
    "TOOL_INTEGRITIES",
    "TOOL_URLS",
)

# A module to use instead of the release's: the absolute path of a file, or a
# URL (`http://`, `https://`, `file://`), for instance the output of
# `bazel build --config=wasm32 @rules_kconfig//kconfig/private/parser:kconfig_wasm`.
# A source checkout of rules_kconfig has no builds of its own and needs this
# or `RULES_KCONFIG_TOOL`.
MODULE_ENV = "RULES_KCONFIG_WASM"

# The expected integrity (`sha256-<base64>`) of a module named by a URL in
# `RULES_KCONFIG_WASM`; optional.
MODULE_INTEGRITY_ENV = "RULES_KCONFIG_WASM_INTEGRITY"

# A native build to use instead of the release's, likewise: for instance the
# output of `bazel build @rules_kconfig//kconfig/private/parser:kconfig_tool`.
TOOL_ENV = "RULES_KCONFIG_TOOL"

# The expected integrity of a native build named by a URL in
# `RULES_KCONFIG_TOOL`; optional.
TOOL_INTEGRITY_ENV = "RULES_KCONFIG_TOOL_INTEGRITY"

# Whether to run the module where Bazel can: `0` (or `false`, `no`, `off`)
# takes the native build instead, where there is one, as Bazel interprets
# the module, which on a large tree is many times slower than the native
# build. Unset or `1` runs the module. Read only where Bazel can run the
# module; elsewhere the native build is the only one, and the variable is
# not looked at. A value that is neither is a warning, and reads as unset.
USE_WASM_ENV = "RULES_KCONFIG_USE_WASM"

_TRUE = ("1", "true", "yes", "on")
_FALSE = ("0", "false", "no", "off")

_EXPORT = "run"
_MEMORY_LIMIT = 512 * 1024 * 1024
_TIMEOUT = 600
_MAX_ROUNDS = 256

# Starlark has no `while`; a tree with more directories than this is an error.
_MAX_TREE_DIRS = 1000000

# The environment variables the parser reads of its own accord: the prefix
# of the symbols and the header of the `.config`. A Kconfig file may name any other, through `$(NAME)` or
# `option env=`; the parser asks for those as it meets them, like files.
_PARSER_ENV = [
    "CONFIG_",
    "KCONFIG_CONFIG_HEADER",
]

def _getenv(ctx, name):
    if hasattr(ctx, "getenv"):
        return ctx.getenv(name)
    return ctx.os.environ.get(name)

def _is_url(location):
    return location.startswith(("http://", "https://", "file://"))

def _is_windows(ctx):
    return ctx.os.name.lower().startswith("windows")

def host_key(ctx):
    """The `<os>-<cpu>` of the host, as `TOOL_URLS` keys it; None if unknown.

    Args:
        ctx: A module extension's or repository rule's context.

    Returns:
        str: For instance `"linux-x86_64"`.
    """
    os_name = ctx.os.name.lower()
    if os_name.startswith("linux"):
        os = "linux"
    elif os_name.startswith("mac"):
        os = "macos"
    elif os_name.startswith("windows"):
        os = "windows"
    else:
        return None
    arch = ctx.os.arch.lower()
    if arch in ("amd64", "x86_64", "x64"):
        cpu = "x86_64"
    elif arch in ("aarch64", "arm64"):
        cpu = "aarch64"
    else:
        return None
    return "{}-{}".format(os, cpu)

def tool_filename(ctx):
    """The name of the native build in the `kconfig_parser` repository.

    Args:
        ctx: A module extension's or repository rule's context.

    Returns:
        str: `kconfig_tool`, with `.exe` on Windows.
    """
    return "kconfig_tool.exe" if _is_windows(ctx) else "kconfig_tool"

def _location(ctx, env, integrity_env, url, integrity):
    """Where a build comes from: the environment's override, the release's, or nowhere."""
    override = _getenv(ctx, env)
    if override:
        if _is_url(override):
            return struct(
                url = override,
                integrity = _getenv(ctx, integrity_env) or "",
                path = None,
            )
        return struct(url = None, integrity = "", path = override)
    if url and integrity:
        return struct(url = url, integrity = integrity, path = None)
    return None

def parser_location(module_ctx):
    """Where the parser's builds come from, for the `kconfig_parser` repository.

    Args:
        module_ctx: The module extension's context.

    Returns:
        struct: `wasm` and `tool`, each `url` and `integrity`, or `path`, or
            None where this checkout has no such build for the host and the
            environment names none.
    """
    key = host_key(module_ctx)
    return struct(
        wasm = _location(module_ctx, MODULE_ENV, MODULE_INTEGRITY_ENV, MODULE_URL, MODULE_INTEGRITY),
        tool = _location(
            module_ctx,
            TOOL_ENV,
            TOOL_INTEGRITY_ENV,
            TOOL_URLS.get(key),
            TOOL_INTEGRITIES.get(key, ""),
        ),
    )

def _fetch(repository_ctx, env, url, integrity, path, output, executable):
    """Bring one build into the repository as `output`; the files it made."""
    if path:
        source = repository_ctx.path(path)
        repository_ctx.watch(source)
        if not source.exists:
            fail("{} names `{}`, which does not exist".format(env, path))
        repository_ctx.symlink(source, output)
    elif url:
        repository_ctx.download(
            url = url,
            output = output,
            integrity = integrity,
            executable = executable,
        )
    else:
        return []
    return [output]

def _kconfig_parser_repository_impl(repository_ctx):
    attr = repository_ctx.attr
    files = _fetch(repository_ctx, MODULE_ENV, attr.wasm_url, attr.wasm_integrity, attr.wasm_path, "kconfig.wasm", False)
    files += _fetch(repository_ctx, TOOL_ENV, attr.tool_url, attr.tool_integrity, attr.tool_path, tool_filename(repository_ctx), True)
    repository_ctx.file("BUILD.bazel", "exports_files({})\n".format(json.encode(files)))

kconfig_parser_repository = repository_rule(
    doc = "Holds the parser's builds the host can use, the WebAssembly module and the native build, downloaded from a release or taken from local builds.",
    implementation = _kconfig_parser_repository_impl,
    attrs = {
        "tool_integrity": attr.string(
            doc = "The expected integrity of the native build at `tool_url`; may be empty.",
        ),
        "tool_path": attr.string(
            doc = "The absolute path of a native build, used instead of `tool_url`.",
        ),
        "tool_url": attr.string(
            doc = "Where to download the native build from.",
        ),
        "wasm_integrity": attr.string(
            doc = "The expected integrity of the module at `wasm_url`; may be empty.",
        ),
        "wasm_path": attr.string(
            doc = "The absolute path of a module, used instead of `wasm_url`.",
        ),
        "wasm_url": attr.string(
            doc = "Where to download the module from.",
        ),
    },
)

def _use_wasm(repository_ctx):
    """Whether `RULES_KCONFIG_USE_WASM` allows the module; True when unset."""
    value = _getenv(repository_ctx, USE_WASM_ENV)
    if value == None or value.strip() == "" or value.strip().lower() in _TRUE:
        return True
    if value.strip().lower() in _FALSE:
        return False

    # buildifier: disable=print
    print("{} is '{}', which is neither of {} nor of {}; the module is used as if it were unset".format(
        USE_WASM_ENV,
        value,
        ", ".join(_TRUE),
        ", ".join(_FALSE),
    ))
    return True

def select_backend(repository_ctx):
    """Decide how to generate a repository.

    The WebAssembly module is used whenever Bazel can run it (Bazel 9.3 or
    newer with `--experimental_repository_ctx_execute_wasm`) and there is one,
    unless `RULES_KCONFIG_USE_WASM=0` (through `--repo_env`) asks for the
    native build; otherwise the native build, where there is one for the
    host, and the variable is not read. A release carries both; `RULES_KCONFIG_WASM` and
    `RULES_KCONFIG_TOOL` name them for a source checkout. Without either the
    repository cannot be generated.

    Args:
        repository_ctx: The repository rule's context. Its rule has the
            `wasm_module` and `tool` attributes (labels, or None).

    Returns:
        struct: `name` is `"wasm"` or `"native"`; `module` is the path of the
            module for `"wasm"`, `tool` the path of the native build for
            `"native"`.
    """

    # The build is an input of the repository: a source checkout names one
    # that is rebuilt in place, and the repository is generated again with it.
    def watched(label):
        path = repository_ctx.path(label)
        repository_ctx.watch(path)
        return path

    can_run_module = hasattr(repository_ctx, "execute_wasm")
    use_wasm = can_run_module and _use_wasm(repository_ctx)
    if use_wasm and repository_ctx.attr.wasm_module:
        return struct(
            name = "wasm",
            module = watched(repository_ctx.attr.wasm_module),
            tool = None,
        )
    if repository_ctx.attr.tool:
        return struct(
            name = "native",
            module = None,
            tool = watched(repository_ctx.attr.tool),
        )
    if not can_run_module:
        module_reason = "Bazel does not expose `execute_wasm` (Bazel 9.3 or newer with `--experimental_repository_ctx_execute_wasm`)"
    elif not use_wasm:
        module_reason = "{}={} asks for the native build".format(USE_WASM_ENV, _getenv(repository_ctx, USE_WASM_ENV))
    else:
        module_reason = "this checkout of rules_kconfig carries no module (build one with `bazel build --config=wasm32 @rules_kconfig//kconfig/private/parser:kconfig_wasm` and name it with {})".format(MODULE_ENV)
    fail(
        "{} cannot be generated: neither build of the parser can be used. {}; ".format(repository_ctx.name, module_reason) +
        "and there is no native build for this host (a release has them for {}; a source checkout needs ".format(", ".join(sorted(TOOL_URLS))) +
        "`bazel build @rules_kconfig//kconfig/private/parser:kconfig_tool`, named with {}).".format(TOOL_ENV),
    )

def new_request(repository_ctx, command, kconfig, srctree, env = {}):
    """The request of a first round.

    The source tree is read ahead, every directory's listing and every
    `Kconfig*` file, and so are the environment variables the parser reads on
    its own, so that the first round sees the whole tree and only what cannot
    be known ahead takes another: `$(shell,...)` commands, files with other
    names, and variables a Kconfig names.

    Args:
        repository_ctx: The repository rule's context.
        command: `"repository"` or `"overrides"`.
        kconfig: The path of the root Kconfig file.
        srctree: The path of the source tree.
        env: The variables the Kconfig tree is given, over the repository
            rule's environment (`repository_ctx.getenv`).

    Returns:
        dict: The request, to be completed with the command's fields.
    """
    variables = dict(env)
    for name in _PARSER_ENV:
        if name not in variables:
            variables[name] = repository_ctx.getenv(name)
    request = {
        "command": command,
        "dirs": {},
        "env": variables,
        "files": {},
        "kconfig": str(kconfig),
        "shell": {},
        "srctree": str(srctree),
    }
    _seed_tree(repository_ctx, request, srctree)
    return request

def seed_file(repository_ctx, request, path):
    """Read a file into the request ahead of the first round.

    Args:
        repository_ctx: The repository rule's context.
        request: A request from `new_request`.
        path: The path of the file, which is recorded as an input.
    """
    request["files"][str(path)] = _stat(repository_ctx, str(path))

def _seed_tree(repository_ctx, request, srctree):
    """Read the source tree into the request ahead of the first round.

    Every directory's listing and every `Kconfig*` file, the files recorded as
    inputs as `_stat` records them. A directory reached through a symlink
    that leaves the tree is not read ahead (a workspace's `bazel-out` leads
    into the output base, and into the repository being generated); the
    parser asks for what it needs there. `.git` is not a source.

    Args:
        repository_ctx: The repository rule's context.
        request: A request from `new_request`.
        srctree: The path of the source tree.
    """

    # The parser asks for files under `srctree` as the request names it.
    def record(kind, path, value):
        request[kind][str(path)] = value

    tree_real = str(srctree.realpath)
    stack = [srctree]
    seen = {}
    for _ in range(_MAX_TREE_DIRS):
        if not stack:
            return
        directory = stack.pop()
        real = str(directory.realpath)
        if real in seen or (real != tree_real and not real.startswith(tree_real + "/")):
            continue
        seen[real] = True
        entries = directory.readdir()
        record("dirs", directory, [[entry.basename, entry.is_dir] for entry in entries])
        for entry in entries:
            if entry.is_dir:
                if entry.basename != ".git":
                    stack.append(entry)
            elif entry.basename.startswith("Kconfig"):
                record("files", entry, _stat(repository_ctx, str(entry)))
    fail("{} has more than {} directories".format(srctree, _MAX_TREE_DIRS))

def host_independent(request, replayed = {}):
    """Whether a finished request took nothing from the host but its files.

    Files and environment variables are recorded inputs, so a repository that
    ran no `$(shell,...)` command is a function of its inputs, which lets it
    be shared through the repo contents cache
    (`repository_ctx.repo_metadata(reproducible = True)`).

    Args:
        request: The request `run_parser` finished with.
        replayed: The `$(shell,...)` answers the request was given from a
            manifest, which are a file's, not the host's.

    Returns:
        bool: Whether the repository is reproducible.
    """
    return not [command for command in request["shell"] if command not in replayed]

def _stat(repository_ctx, path):
    """What the parser asks of a file: whether it exists, and its content."""
    target = repository_ctx.path(path)
    if not target.exists:
        repository_ctx.watch(target)
        return {"content": None, "exists": False, "is_dir": False}
    if target.is_dir:
        repository_ctx.watch(target)
        return {"content": None, "exists": True, "is_dir": True}
    return {"content": repository_ctx.read(target), "exists": True, "is_dir": False}

def _shell(repository_ctx, command, srctree, env):
    """Run a `$(shell,...)` command as `conf` would, in the tree's variables."""
    if _is_windows(repository_ctx):
        argv = ["cmd.exe", "/c", command]
    else:
        argv = ["/bin/sh", "-c", command]
    result = repository_ctx.execute(
        argv,
        timeout = _TIMEOUT,
        environment = dict(env, srctree = str(srctree)),
        quiet = True,
        working_directory = str(srctree),
    )
    return {
        "return_code": result.return_code,
        "stderr": result.stderr,
        "stdout": result.stdout,
    }

def _call_wasm(repository_ctx, module, payload):
    """One round with the module."""
    result = repository_ctx.execute_wasm(
        module,
        _EXPORT,
        input = payload,
        timeout = _TIMEOUT,
        memory_limit = _MEMORY_LIMIT,
    )
    if result.return_code != 0:
        fail("The kconfig module failed (code {}): {}\n{}".format(
            result.return_code,
            result.error_message,
            result.output,
        ))
    return result.output

def _call_tool(repository_ctx, tool, scratch, payload):
    """One round with the native build: the request in a file, the response in another.

    `repository_ctx.execute` has no standard input, and its standard output
    is text; files carry the bytes through unchanged.
    """
    request_path = scratch.get_child("request.json")
    response_path = scratch.get_child("response.json")
    repository_ctx.file(request_path, payload, executable = False, legacy_utf8 = False)
    result = repository_ctx.execute(
        [tool, request_path, response_path],
        timeout = _TIMEOUT,
        quiet = True,
    )
    if result.return_code != 0:
        fail("The kconfig parser failed (code {}):\n{}".format(result.return_code, result.stderr))
    return repository_ctx.read(response_path, watch = "no")

def run_parser(repository_ctx, backend, request, env = {}):
    """Run the parser until it produces the repository's files.

    Args:
        repository_ctx: The repository rule's context.
        backend: From `select_backend`, `"wasm"` or `"native"`.
        request: A request from `new_request`, completed for its command.
        env: The variables the Kconfig tree is given, as `new_request` had
            them: a variable the parser asks for is answered from these before
            the repository rule's environment, and `$(shell,...)` commands run
            with them set.

    Returns:
        dict: The parser's `ok` response: `files` maps repository paths to
            contents, `manifest` is the repository's manifest where there is one.
    """

    # What may wait on Bazel (a path into another repository) comes before
    # the parser is loaded, so the rounds, which are the expensive part, run
    # uninterrupted.
    srctree = repository_ctx.path(request["srctree"])
    module = None
    scratch = None
    if backend.name == "wasm":
        module = repository_ctx.load_wasm(backend.module)
    else:
        scratch = repository_ctx.path(".kconfig_parser")

    for _ in range(_MAX_ROUNDS):
        payload = json.encode(request)
        if module != None:
            output = _call_wasm(repository_ctx, module, payload)
        else:
            output = _call_tool(repository_ctx, backend.tool, scratch, payload)
        response = json.decode(output)
        status = response.get("status")
        if status == "ok":
            if scratch != None:
                repository_ctx.delete(scratch)
            return response
        if status == "error":
            fail("Failed to generate the kconfig repository:\n{}".format(response.get("message")))
        if status != "need":
            fail("The kconfig parser answered with an unknown status: {}".format(status))

        for path in response.get("files", []):
            request["files"][path] = _stat(repository_ctx, path)
        for command in response.get("shell", []):
            request["shell"][command] = _shell(repository_ctx, command, srctree, env)
        for name in response.get("env", []):
            request["env"][name] = env[name] if name in env else repository_ctx.getenv(name)

    fail("The kconfig parser did not finish within {} rounds".format(_MAX_ROUNDS))

def write_files(repository_ctx, files):
    """Write the parser's output files into the repository.

    Args:
        repository_ctx: The repository rule's context.
        files: `path` to content, from an `ok` response.
    """
    for path, content in files.items():
        repository_ctx.file(path, content, executable = False, legacy_utf8 = False)
