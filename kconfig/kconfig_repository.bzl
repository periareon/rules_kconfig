"""kconfig_repository"""

load(
    "//kconfig/private:parser_backend.bzl",
    "host_independent",
    "new_request",
    "run_parser",
    "seed_file",
    "select_backend",
    "write_files",
)
load("//kconfig/private:versions.bzl", "DEFAULT_KCONFIG_VERSION", "PARSER_VERSIONS", "parser_version")

def _config_ws_path(label):
    return (label.package + "/" + label.name).lstrip("/")

def _generate_with_parser(repository_ctx, backend, kconfig, repo_name):
    """Run the parser, which reads the Kconfig tree through this rule."""
    env = dict(repository_ctx.attr.env)

    # A variable that names a file, such as a downloaded toolchain's compiler:
    # its path, which the manifest records for the overrides layered on this
    # repository.
    for label, name in repository_ctx.attr.env_labels.items():
        path = repository_ctx.path(label)
        repository_ctx.watch(path)
        env[name] = str(path)
    request = new_request(repository_ctx, "repository", kconfig, kconfig.dirname, env = env)
    request["repo_name"] = repo_name
    request["kconfig_version"] = repository_ctx.attr.kconfig_version
    request["parser_version"] = parser_version(repository_ctx.attr.kconfig_version, repository_ctx.name)
    request["defaults"] = None
    request["config_ws_path"] = None
    request["kconfig_env"] = env
    request["settings_labels"] = dict(repository_ctx.attr.settings_labels)
    request["settings_options"] = {
        name: list(values)
        for name, values in repository_ctx.attr.settings_options.items()
    }
    if repository_ctx.attr.defaults:
        defaults = repository_ctx.path(repository_ctx.attr.defaults)
        request["defaults"] = str(defaults)
        request["config_ws_path"] = _config_ws_path(repository_ctx.attr.defaults)
        seed_file(repository_ctx, request, defaults)
    response = run_parser(repository_ctx, backend, request, env = env)
    write_files(repository_ctx, response["files"])
    return struct(
        manifest = response["manifest"],
        reproducible = host_independent(request),
    )

def _kconfig_repository_impl(repository_ctx):
    kconfig = repository_ctx.path(repository_ctx.attr.kconfig)
    repo_name = repository_ctx.attr.apparent_name or repository_ctx.name
    manifest_file = repository_ctx.path("kconfig.manifest.json")
    generated = _generate_with_parser(repository_ctx, select_backend(repository_ctx), kconfig, repo_name)

    kconfig_dir = kconfig.dirname
    for f in generated.manifest["files"]:
        src = kconfig_dir.get_child(f)
        repository_ctx.watch(src)
        repository_ctx.symlink(src, "kconfig_srcs/" + f)

    repository_ctx.symlink(manifest_file, repo_name)

    repository_ctx.file("WORKSPACE.bazel", """workspace(name = "{}")""".format(
        repository_ctx.name,
    ))

    # A reproducible repository may be taken from the repo contents cache
    # instead of generated again.
    if generated.reproducible and hasattr(repository_ctx, "repo_metadata"):
        return repository_ctx.repo_metadata(reproducible = True)
    return None

kconfig_repository = repository_rule(
    doc = """\
Parse a Kconfig file tree and generate a Bazel repository with build settings.

The generated repository contains a `bool_flag`, `int_flag`, or `string_flag`
for every `config` symbol found in the Kconfig tree, plus a `cc_library`
target (`:config`) providing a `config.h` header that reflects the active
flag values.

The Kconfig source tree is symlinked into `kconfig_srcs/` and a
`kconfig.manifest.json` records the root file and all visited files.
A repo-named symlink (e.g. `@my_kconfig//:my_kconfig`) points to
the manifest for downstream consumers.

The Kconfig tree is parsed by the kernel's parser of the release
`kconfig_version` names, as the WebAssembly module a release of rules_kconfig
carries (Bazel 9.3 or newer with `--experimental_repository_ctx_execute_wasm`)
or as the release's native build for the host; both generate the same
repository.

Prefer using the `kconfig` module extension rather than calling this rule
directly.
""",
    implementation = _kconfig_repository_impl,
    attrs = {
        "apparent_name": attr.string(
            doc = "The user-facing repository name (used for the repo-named symlink). Defaults to the canonical name.",
        ),
        "defaults": attr.label(
            doc = "Optional .config file with explicit symbol values that override Kconfig defaults.",
        ),
        "env": attr.string_dict(
            doc = """\
Environment variables for the Kconfig tree: what `$(NAME)` and `option env`
read, and the environment of `$(shell,...)` commands, over the repository
rule's own environment (`--repo_env`). The kernel's tree reads `ARCH`,
`SRCARCH`, `CC`, `LD` and others its Makefile exports, so that several
architectures' repositories can be generated in one workspace. The variables
are recorded in the manifest and apply to `kconfig_overrides_repository`
layered on the repository.
""",
            default = {},
        ),
        "env_labels": attr.label_keyed_string_dict(
            doc = """\
Files as environment variables for the Kconfig tree: each label's path is
the value of the variable it maps to, over `env`. For the tools a tree's
`$(shell,...)` probes run, `CC`, `LD` or `RUSTC`, a label into a downloaded
toolchain's repository (`@llvm_toolchain_llvm//:bin/clang`) runs that
toolchain's binary on the host; a repository rule cannot resolve the
toolchain Bazel would pick for a platform.
""",
            default = {},
        ),
        "kconfig": attr.label(
            doc = "The root Kconfig file to parse. All files referenced via `source` directives are followed automatically.",
            mandatory = True,
        ),
        "kconfig_version": attr.string(
            doc = """\
The kernel release the tree is written for: `{default}` (the default), `6.12.7`,
`4.19`. Kconfig has no version of its own, so this is the release of the
kernel tree, or the one a project's copy of `scripts/kconfig` was synced
from (U-Boot: `4.19`). The tree is parsed and resolved as that release's
`conf` would, by the newest parser rules_kconfig builds at or below the
version ({parsers}); a version below the oldest is an error. The version is
recorded in the manifest, and the overrides layered on the repository use
the same.
""".format(
                default = DEFAULT_KCONFIG_VERSION,
                parsers = ", ".join(["`{}`".format(v) for v in PARSER_VERSIONS]),
            ),
            default = DEFAULT_KCONFIG_VERSION,
        ),
        "settings_labels": attr.string_dict(
            doc = """\
Map of `CONFIG_*` names to label strings for user-provided rules that replace
generated flags. The label must point to a target that provides
BuildSettingInfo. Use this for symbols whose values depend on the build
configuration (e.g. toolchain-derived values like compiler version).
""",
            default = {},
        ),
        "settings_options": attr.string_list_dict(
            doc = "Optional map of CONFIG_* names to lists of string values for generated config_settings.",
            default = {},
        ),
        "tool": attr.label(
            doc = """\
The native build of the parser (`kconfig_tool`), used where the WebAssembly
module cannot be. The `kconfig` module extension provides the release's build
for the host, or the one `RULES_KCONFIG_TOOL` names.
""",
        ),
        "wasm_module": attr.label(
            doc = """\
The WebAssembly build of the parser (`kconfig.wasm`), used on Bazel 9.3 or
newer with `--experimental_repository_ctx_execute_wasm`, unless
`RULES_KCONFIG_USE_WASM=0` (through `--repo_env`) asks for the native build.
The `kconfig` module extension provides the release's module, or the one
`RULES_KCONFIG_WASM` names.
""",
        ),
    },
)
