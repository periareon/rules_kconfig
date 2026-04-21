"""kconfig_repository"""

def _find_kconfiglib(repository_ctx):
    """Resolve the directory containing kconfiglib from the anchor label."""
    return repository_ctx.path(repository_ctx.attr.kconfiglib_anchor).dirname

def _rules_kconfig_root(repository_ctx):
    """Derive the rules_kconfig repo root from the _kconfig_parser label."""
    return str(repository_ctx.path(repository_ctx.attr._kconfig_parser).dirname.dirname.dirname)

def _kconfig_repository_impl(repository_ctx):
    python = repository_ctx.path(repository_ctx.attr.interpreter)
    kconfiglib = _find_kconfiglib(repository_ctx)
    generator = repository_ctx.path(repository_ctx.attr._repository_gen)
    repository_ctx.watch(generator)

    parser = repository_ctx.path(repository_ctx.attr._kconfig_parser)
    repository_ctx.watch(parser)

    kconfig = repository_ctx.path(repository_ctx.attr.kconfig)

    build_file = repository_ctx.path("BUILD.bazel")
    manifest_file = repository_ctx.path("kconfig.manifest.json")
    config_h_in_file = repository_ctx.path("config.h.in")

    repo_name = repository_ctx.attr.apparent_name or repository_ctx.name

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

        defaults_label = repository_ctx.attr.defaults
        config_ws_path = (defaults_label.package + "/" + defaults_label.name).lstrip("/")
        cmd.extend(["--config_ws_path", config_ws_path])

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

    manifest = json.decode(repository_ctx.read(manifest_file))
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
            doc = "A Python interpreter target used to run the Kconfig parser.",
            mandatory = True,
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
        "_kconfig_parser": attr.label(
            default = Label("//kconfig/private:kconfig_parser.py"),
        ),
        "_repository_gen": attr.label(
            default = Label("//kconfig/private:repository_gen.py"),
        ),
    },
)
