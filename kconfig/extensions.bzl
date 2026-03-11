"""Module extension for declaring kconfig repositories."""

load("//kconfig:kconfig_repository.bzl", "kconfig_repository")
load("//kconfig/private:kconfiglib.bzl", "kconfiglib_repository")

_LOAD = tag_class(
    doc = "Declare a kconfig repository to be generated from a Kconfig file tree.",
    attrs = {
        "config": attr.label(
            doc = "The root Kconfig file to parse. All files referenced via `source` directives are followed automatically.",
            mandatory = True,
        ),
        "interpreter": attr.label(
            doc = "A Python interpreter target used to run the Kconfig parser (e.g. `@python_3_12_host//:python`).",
            mandatory = True,
        ),
        "name": attr.string(
            doc = "The name of the generated repository. Symbols are accessible as `@<name>//:CONFIG_<symbol>`.",
            mandatory = True,
        ),
    },
)

def _kconfig_impl(module_ctx):
    kconfiglib_repository(
        name = "kconfiglib",
    )

    for module in module_ctx.modules:
        for tag in getattr(module.tags, "repo", []):
            kconfig_repository(
                name = tag.name,
                config = tag.config,
                kconfiglib_anchor = "@kconfiglib//:BUILD.bazel",
                interpreter = tag.interpreter,
            )

    return module_ctx.extension_metadata(reproducible = True)

kconfig = module_extension(
    doc = "Configure kconfig repositories.",
    implementation = _kconfig_impl,
    tag_classes = {
        "repo": _LOAD,
    },
)
