"""Module extension for declaring kconfig repositories."""

load("//kconfig:kconfig_overrides_repository.bzl", "kconfig_overrides_repository")
load("//kconfig:kconfig_repository.bzl", "kconfig_repository")
load("//kconfig/private:kconfiglib.bzl", "kconfiglib_repository")
load("//kconfig/private:wasm_backend.bzl", "kconfig_wasm_repository", "wasm_module_location")

_LOAD = tag_class(
    doc = "Declare a kconfig repository to be generated from a Kconfig file tree.",
    attrs = {
        "defaults": attr.label(
            doc = "Optional .config file providing default overrides for Kconfig symbols.",
        ),
        "interpreter": attr.label(
            doc = """\
A Python interpreter target used to run the Kconfig parser (e.g. `@python_3_14_host//:python`).

Not needed on Bazel 9.3 or newer with `--experimental_repository_ctx_execute_wasm`,
where a release of rules_kconfig parses with its WebAssembly module instead;
required otherwise.
""",
        ),
        "kconfig": attr.label(
            doc = "The root Kconfig file to parse. All files referenced via `source` directives are followed automatically.",
            mandatory = True,
        ),
        "name": attr.string(
            doc = "The name of the generated repository. Symbols are accessible as `@<name>//:CONFIG_<symbol>`.",
            mandatory = True,
        ),
        "settings_labels": attr.label_keyed_string_dict(
            doc = """\
Map of user-provided rule labels to CONFIG_* names they replace. Each label
must point to a target that provides BuildSettingInfo. Use this for symbols
whose values depend on the build configuration (e.g. toolchain-derived values
like compiler version).
""",
            default = {},
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
            doc = "A Python interpreter target (e.g. `@python_3_14_host//:python`). See `kconfig.repo`.",
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

    # The WebAssembly backend of this release, or the one `RULES_KCONFIG_WASM`
    # names; fetched only when a repository is generated with it.
    wasm_module = None
    location = wasm_module_location(module_ctx)
    if location != None:
        kconfig_wasm_repository(
            name = "kconfig_wasm",
            integrity = location.integrity,
            path = location.path,
            url = location.url,
        )
        wasm_module = "@kconfig_wasm//:kconfig.wasm"

    for module in module_ctx.modules:
        for tag in getattr(module.tags, "repo", []):
            settings_labels = {v: str(k) for k, v in tag.settings_labels.items()}

            kconfig_repository(
                name = tag.name,
                apparent_name = tag.name,
                defaults = tag.defaults,
                kconfig = tag.kconfig,
                kconfiglib_anchor = "@kconfiglib//:BUILD.bazel",
                interpreter = tag.interpreter,
                settings_labels = settings_labels,
                settings_options = tag.settings_options,
                wasm_module = wasm_module,
            )

        for tag in getattr(module.tags, "overrides", []):
            kconfig_overrides_repository(
                name = tag.name,
                kconfig = tag.kconfig,
                config = tag.config,
                kconfiglib_anchor = "@kconfiglib//:BUILD.bazel",
                interpreter = tag.interpreter,
                wasm_module = wasm_module,
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
