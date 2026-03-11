"""kconfig_repository"""

def _find_kconfiglib(repository_ctx):
    """Resolve the directory containing kconfiglib from the anchor label."""
    return repository_ctx.path(repository_ctx.attr.kconfiglib_anchor).dirname

def _kconfig_repository_impl(repository_ctx):
    python = repository_ctx.path(repository_ctx.attr.interpreter)
    kconfiglib = _find_kconfiglib(repository_ctx)
    generator = repository_ctx.path(repository_ctx.attr._repository_gen)
    config = repository_ctx.path(repository_ctx.attr.config)

    build_file = repository_ctx.path("BUILD.bazel")
    manifest_file = repository_ctx.path("kconfig.manifest")
    config_h_in_file = repository_ctx.path("config.h.in")
    result = repository_ctx.execute(
        [
            python,
            "-B",
            "-s",
            "-P",
            generator,
            "--config",
            config,
            "--out_build",
            build_file,
            "--out_manifest",
            manifest_file,
            "--out_config_h_in",
            config_h_in_file,
        ],
        environment = {"PYTHONPATH": str(kconfiglib)},
    )
    if result.return_code != 0:
        fail("Failed to invoke Python: {}".format(result.stderr))

    config_dir = config.dirname
    manifest_contents = repository_ctx.read(manifest_file)
    for line in manifest_contents.splitlines():
        if line:
            repository_ctx.watch(config_dir.get_child(line))

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

Prefer using the `kconfig` module extension rather than calling this rule
directly.
""",
    implementation = _kconfig_repository_impl,
    attrs = {
        "config": attr.label(
            doc = "The root Kconfig file to parse. All files referenced via `source` directives are followed automatically.",
            mandatory = True,
        ),
        "interpreter": attr.label(
            doc = "A Python interpreter target used to run the Kconfig parser.",
            mandatory = True,
        ),
        "kconfiglib_anchor": attr.label(
            doc = "Label used to locate the `kconfiglib` package. Managed by the module extension.",
            mandatory = True,
        ),
        "_repository_gen": attr.label(
            default = Label("//kconfig/private:repository_gen.py"),
        ),
    },
)
