"""kconfig_repository"""

load(
    "//kconfig/private:wasm_backend.bzl",
    "new_request",
    "run_module",
    "select_backend",
    "write_files",
)

def _find_kconfiglib(repository_ctx):
    """Resolve the directory containing kconfiglib from the anchor label."""
    return repository_ctx.path(repository_ctx.attr.kconfiglib_anchor).dirname

def _rules_kconfig_root(repository_ctx):
    """Derive the rules_kconfig repo root from the _kconfig_parser label."""
    return str(repository_ctx.path(repository_ctx.attr._kconfig_parser).dirname.dirname.dirname)

def _config_ws_path(label):
    return (label.package + "/" + label.name).lstrip("/")

def _generate_with_python(repository_ctx, kconfig, repo_name, manifest_file):
    """Run `repository_gen.py` with the `interpreter`."""
    python = repository_ctx.path(repository_ctx.attr.interpreter)
    kconfiglib = _find_kconfiglib(repository_ctx)
    generator = repository_ctx.path(repository_ctx.attr._repository_gen)
    repository_ctx.watch(generator)

    parser = repository_ctx.path(repository_ctx.attr._kconfig_parser)
    repository_ctx.watch(parser)

    build_file = repository_ctx.path("BUILD.bazel")
    config_h_in_file = repository_ctx.path("config.h.in")
    rendered_config_file = repository_ctx.path("rendered.config")
    settings_bzl_file = repository_ctx.path("settings.bzl")
    settings_build_file = repository_ctx.path("settings/BUILD.bazel")

    cmd = [
        python,
        "-B",
        "-s",
        "-P",
        generator,
        "--kconfig",
        kconfig,
        "--out_build",
        build_file,
        "--out_manifest",
        manifest_file,
        "--out_config_h_in",
        config_h_in_file,
        "--out_rendered_config",
        rendered_config_file,
        "--out_settings_bzl",
        settings_bzl_file,
        "--out_settings_build",
        settings_build_file,
        "--repo_name",
        repo_name,
    ]

    if repository_ctx.attr.defaults:
        defaults = repository_ctx.path(repository_ctx.attr.defaults)
        cmd.extend(["--defaults", defaults])
        repository_ctx.watch(defaults)
        cmd.extend(["--config_ws_path", _config_ws_path(repository_ctx.attr.defaults)])

    if repository_ctx.attr.settings_options:
        cmd.extend(["--settings_options", json.encode(repository_ctx.attr.settings_options)])

    if repository_ctx.attr.settings_labels:
        cmd.extend(["--settings_labels", json.encode(repository_ctx.attr.settings_labels)])

    rules_root = _rules_kconfig_root(repository_ctx)
    path_sep = ";" if "windows" in repository_ctx.os.name.lower() else ":"
    result = repository_ctx.execute(
        cmd,
        environment = {"PYTHONPATH": "{}{}{}".format(rules_root, path_sep, str(kconfiglib))},
    )
    if result.return_code != 0:
        fail("Failed to invoke Python: {}".format(result.stderr))

    return json.decode(repository_ctx.read(manifest_file))

def _generate_with_wasm(repository_ctx, module, kconfig, repo_name):
    """Run the WebAssembly module, which reads the Kconfig tree through this rule."""
    request = new_request(repository_ctx, "repository", kconfig, kconfig.dirname)
    request["repo_name"] = repo_name
    request["defaults"] = None
    request["config_ws_path"] = None
    request["settings_labels"] = dict(repository_ctx.attr.settings_labels)
    request["settings_options"] = {
        name: list(values)
        for name, values in repository_ctx.attr.settings_options.items()
    }
    if repository_ctx.attr.defaults:
        request["defaults"] = str(repository_ctx.path(repository_ctx.attr.defaults))
        request["config_ws_path"] = _config_ws_path(repository_ctx.attr.defaults)

    response = run_module(repository_ctx, module, request)
    write_files(repository_ctx, response["files"])
    return response["manifest"]

def _kconfig_repository_impl(repository_ctx):
    kconfig = repository_ctx.path(repository_ctx.attr.kconfig)
    repo_name = repository_ctx.attr.apparent_name or repository_ctx.name
    manifest_file = repository_ctx.path("kconfig.manifest.json")

    backend = select_backend(repository_ctx)
    if backend.name == "wasm":
        manifest = _generate_with_wasm(repository_ctx, backend.module, kconfig, repo_name)
    else:
        manifest = _generate_with_python(repository_ctx, kconfig, repo_name, manifest_file)

    kconfig_dir = kconfig.dirname
    for f in manifest["files"]:
        src = kconfig_dir.get_child(f)
        repository_ctx.watch(src)
        repository_ctx.symlink(src, "kconfig_srcs/" + f)

    repository_ctx.symlink(manifest_file, repo_name)

    repository_ctx.file("WORKSPACE.bazel", """workspace(name = "{}")""".format(
        repository_ctx.name,
    ))

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

The Kconfig tree is parsed by kconfiglib, either inside the WebAssembly module
a release of rules_kconfig carries (Bazel 9.3 or newer with
`--experimental_repository_ctx_execute_wasm`; no interpreter needed) or by the
Python `interpreter`. The `interpreter` is ignored when the module is used.

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
        "interpreter": attr.label(
            doc = "A Python interpreter target used to run the Kconfig parser when the WebAssembly backend is not available.",
        ),
        "kconfig": attr.label(
            doc = "The root Kconfig file to parse. All files referenced via `source` directives are followed automatically.",
            mandatory = True,
        ),
        "kconfiglib_anchor": attr.label(
            doc = "Label used to locate the `kconfiglib` package. Managed by the module extension.",
            mandatory = True,
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
        "wasm_module": attr.label(
            doc = """\
The WebAssembly backend (`kconfig.wasm`), used on Bazel 9.3 or newer with
`--experimental_repository_ctx_execute_wasm`. The `kconfig` module extension
provides the module of the release, or the one `RULES_KCONFIG_WASM` names; without
one the Python `interpreter` is used.
""",
        ),
        "_kconfig_parser": attr.label(
            default = Label("//kconfig/private:kconfig_parser.py"),
        ),
        "_repository_gen": attr.label(
            default = Label("//kconfig/private:repository_gen.py"),
        ),
    },
)
