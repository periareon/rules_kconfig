"""kconfig_overrides_repository rule for overlaying .config onto an external kconfig repo."""

def _find_kconfiglib(repository_ctx):
    """Resolve the directory containing kconfiglib from the anchor label."""
    return repository_ctx.path(repository_ctx.attr.kconfiglib_anchor).dirname

def _rules_kconfig_root(repository_ctx):
    """Derive the rules_kconfig repo root from the _kconfig_parser label."""
    return str(repository_ctx.path(repository_ctx.attr._kconfig_parser).dirname.dirname.dirname)

def _kconfig_overrides_repository_impl(repository_ctx):
    python = repository_ctx.path(repository_ctx.attr.interpreter)
    kconfiglib = _find_kconfiglib(repository_ctx)
    generator = repository_ctx.path(repository_ctx.attr._overrides_gen)
    repository_ctx.watch(generator)

    parser = repository_ctx.path(repository_ctx.attr._kconfig_parser)
    repository_ctx.watch(parser)

    config = repository_ctx.path(repository_ctx.attr.config)

    manifest_path = repository_ctx.path(repository_ctx.attr.kconfig)
    manifest = json.decode(repository_ctx.read(manifest_path))
    kconfig_srcs = manifest_path.dirname.get_child("kconfig_srcs")
    kconfig_root = kconfig_srcs.get_child(manifest["root"])

    kconfig_repo = str(repository_ctx.attr.kconfig).split("//")[0]

    defs_file = repository_ctx.path("defs.bzl")
    build_file = repository_ctx.path("BUILD.bazel")

    cmd = [
        python,
        "-B",
        "-s",
        "-P",
        generator,
        "--kconfig",
        kconfig_root,
        "--srctree",
        kconfig_srcs,
        "--config",
        config,
        "--kconfig_repo",
        kconfig_repo,
        "--out_defs",
        defs_file,
        "--out_build",
        build_file,
    ]

    base_config = manifest.get("config")
    if base_config:
        base_config_path = manifest_path.dirname.get_child(base_config)
        repository_ctx.watch(base_config_path)
        cmd.extend(["--base_config", base_config_path])

    rules_root = _rules_kconfig_root(repository_ctx)
    path_sep = ";" if "windows" in repository_ctx.os.name.lower() else ":"
    result = repository_ctx.execute(
        cmd,
        environment = {"PYTHONPATH": "{}{}{}".format(rules_root, path_sep, str(kconfiglib))},
    )
    if result.return_code != 0:
        fail("Failed to generate kconfig overrides: {}".format(result.stderr))

    repository_ctx.watch(config)

    repository_ctx.file("WORKSPACE.bazel", """workspace(name = "{}")""".format(
        repository_ctx.name,
    ))

kconfig_overrides_repository = repository_rule(
    doc = """\
Overlay .config values onto an existing kconfig repository.

Reads the manifest from the source kconfig repository to locate the
symlinked Kconfig source tree, then reparses with kconfiglib and a
user-provided `.config` file. If the source repository was itself
created with a `.config`, the overrides are stacked on top of those
base values. Generates a `defs.bzl` containing a Starlark transition
and wrapper rule (`with_kconfig_overrides`) that applies the overrides.

Values explicitly set on the command line take precedence over the overlay.
""",
    implementation = _kconfig_overrides_repository_impl,
    attrs = {
        "config": attr.label(
            doc = ".config file with override values.",
            mandatory = True,
        ),
        "interpreter": attr.label(
            doc = "A Python interpreter target used to run the generator.",
            mandatory = True,
        ),
        "kconfig": attr.label(
            doc = "Label to the kconfig manifest from the source kconfig repository (e.g. `@my_kconfig//:my_kconfig`).",
            mandatory = True,
        ),
        "kconfiglib_anchor": attr.label(
            doc = "Label used to locate the `kconfiglib` package. Managed by the module extension.",
            mandatory = True,
        ),
        "_kconfig_parser": attr.label(
            default = Label("//kconfig/private:kconfig_parser.py"),
        ),
        "_overrides_gen": attr.label(
            default = Label("//kconfig/private:overrides_gen.py"),
        ),
    },
)
