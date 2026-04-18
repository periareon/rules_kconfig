"""Module extension for declaring kconfig repositories."""

load("//kconfig:kconfig_overrides_repository.bzl", "kconfig_overrides_repository")
load("//kconfig:kconfig_repository.bzl", "kconfig_repository")
load("//kconfig/private:kconfiglib.bzl", "kconfiglib_repository")

_LOAD = tag_class(
    doc = "Declare a kconfig repository to be generated from a Kconfig file tree.",
    attrs = {
        "defaults": attr.label(
            doc = "Optional .config file providing default overrides for Kconfig symbols.",
        ),
        "interpreter": attr.label(
            doc = "A Python interpreter target used to run the Kconfig parser (e.g. `@python_3_12_host//:python`).",
            mandatory = True,
        ),
        "kconfig": attr.label(
            doc = "The root Kconfig file to parse. All files referenced via `source` directives are followed automatically.",
            mandatory = True,
        ),
        "name": attr.string(
            doc = "The name of the generated repository. Symbols are accessible as `@<name>//:CONFIG_<symbol>`.",
            mandatory = True,
        ),
        "settings_options": attr.string_list_dict(
            doc = "Optional map of CONFIG_* names to lists of string values for generated config_settings.",
            default = {},
        ),
    },
)

_OVERRIDES = tag_class(
    doc = "Overlay .config overrides onto an existing kconfig repository.",
    attrs = {
        "config": attr.label(
            doc = ".config file with override values.",
            mandatory = True,
        ),
        "interpreter": attr.label(
            doc = "A Python interpreter target (e.g. `@python_3_12_host//:python`).",
            mandatory = True,
        ),
        "kconfig": attr.label(
            doc = "Label to the kconfig manifest from the source repository (e.g. `@ext_kconfig//:ext_kconfig`).",
            mandatory = True,
        ),
        "name": attr.string(
            doc = "The name of the generated overrides repository.",
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
                apparent_name = tag.name,
                defaults = tag.defaults,
                kconfig = tag.kconfig,
                kconfiglib_anchor = "@kconfiglib//:BUILD.bazel",
                interpreter = tag.interpreter,
                settings_options = tag.settings_options,
            )

        for tag in getattr(module.tags, "overrides", []):
            kconfig_overrides_repository(
                name = tag.name,
                kconfig = tag.kconfig,
                config = tag.config,
                kconfiglib_anchor = "@kconfiglib//:BUILD.bazel",
                interpreter = tag.interpreter,
            )

    return module_ctx.extension_metadata(reproducible = True)

kconfig = module_extension(
    doc = "Configure kconfig repositories.",
    implementation = _kconfig_impl,
    tag_classes = {
        "overrides": _OVERRIDES,
        "repo": _LOAD,
    },
)
