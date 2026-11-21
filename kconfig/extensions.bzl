"""Module extension for declaring kconfig repositories."""

load("//kconfig:kconfig_overrides_repository.bzl", "kconfig_overrides_repository")
load("//kconfig:kconfig_repository.bzl", "kconfig_repository")
load("//kconfig/private:kconfiglib.bzl", "kconfiglib_repository")
load("//kconfig/private:parser_backend.bzl", "kconfig_parser_repository", "parser_location", "tool_filename")
load("//kconfig/private/parser/kernel:repository.bzl", "kernel_kconfig_repository")

_LOAD = tag_class(
    doc = "Declare a kconfig repository to be generated from a Kconfig file tree.",
    attrs = {
        "defaults": attr.label(
            doc = "Optional .config file providing default overrides for Kconfig symbols.",
        ),
        "env": attr.string_dict(
            doc = """\
Environment variables for the Kconfig tree: what `$(NAME)` and `option env`
read, and the environment of `$(shell,...)` commands, over the repository
rule's own environment (`--repo_env`). The kernel's tree reads `ARCH`,
`SRCARCH`, `CC`, `LD` and others its Makefile exports, so that several
architectures' repositories can be generated in one workspace.
""",
            default = {},
        ),
        "env_labels": attr.label_keyed_string_dict(
            doc = """\
Files as environment variables for the Kconfig tree, each label mapped to
the name of its variable: a downloaded toolchain's compiler as `CC`, for
the tree's `$(shell,...)` probes to run (`{"@llvm_toolchain_llvm//:bin/clang": "CC"}`).
The label's path is the value, over `env`.
""",
            default = {},
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
    # kconfiglib, for `menuconfig`.
    kconfiglib_repository(
        name = "kconfiglib",
    )

    # The kernel's parser, for building the WebAssembly module; fetched only
    # when it is.
    kernel_kconfig_repository(
        name = "kernel_kconfig",
    )

    # The parser's builds of this release the host can use, or the ones
    # `RULES_KCONFIG_WASM` and `RULES_KCONFIG_TOOL` name; fetched only when a
    # repository is generated with them.
    wasm_module = None
    tool = None
    location = parser_location(module_ctx)
    if location.wasm != None or location.tool != None:
        wasm = location.wasm or struct(url = None, integrity = "", path = None)
        native = location.tool or struct(url = None, integrity = "", path = None)
        kconfig_parser_repository(
            name = "kconfig_parser",
            tool_integrity = native.integrity,
            tool_path = native.path,
            tool_url = native.url,
            wasm_integrity = wasm.integrity,
            wasm_path = wasm.path,
            wasm_url = wasm.url,
        )
        if location.wasm != None:
            wasm_module = "@kconfig_parser//:kconfig.wasm"
        if location.tool != None:
            tool = "@kconfig_parser//:" + tool_filename(module_ctx)

    for module in module_ctx.modules:
        for tag in getattr(module.tags, "repo", []):
            settings_labels = {v: str(k) for k, v in tag.settings_labels.items()}

            kconfig_repository(
                name = tag.name,
                apparent_name = tag.name,
                defaults = tag.defaults,
                env = tag.env,
                env_labels = tag.env_labels,
                kconfig = tag.kconfig,
                settings_labels = settings_labels,
                settings_options = tag.settings_options,
                tool = tool,
                wasm_module = wasm_module,
            )

        for tag in getattr(module.tags, "overrides", []):
            kconfig_overrides_repository(
                name = tag.name,
                kconfig = tag.kconfig,
                config = tag.config,
                tool = tool,
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
