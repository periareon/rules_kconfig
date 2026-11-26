"""Module extension for declaring kconfig repositories."""

load("//kconfig:kconfig_overrides_repository.bzl", "kconfig_overrides_repository")
load("//kconfig:kconfig_repository.bzl", "kconfig_repository")
load("//kconfig/private:parser_backend.bzl", "kconfig_parser_repository", "parser_location", "tool_filename")
load("//kconfig/private:versions.bzl", "DEFAULT_KCONFIG_VERSION", "PARSER_VERSIONS", "parser_version")
load("//kconfig/private/parser/kernel:repository.bzl", "kernel_kconfig_repository", "kernel_kconfig_repository_name")

_KCONFIG_VERSION_DOC = """\
The kernel release the tree is written for: `{default}` (the default), `6.12.7`,
`4.19`. Kconfig has no version of its own, so this is the release of the
kernel tree, or the one a project's copy of `scripts/kconfig` was synced
from. The tree is parsed and resolved as that release's
`conf` would, by the newest parser rules_kconfig builds at or below the
version ({parsers}); a version below the oldest is an error. The version is
recorded in the manifest, and the overrides layered on the repository use
the same.
""".format(
    default = DEFAULT_KCONFIG_VERSION,
    parsers = ", ".join(["`{}`".format(v) for v in PARSER_VERSIONS]),
)

_REPO = tag_class(
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
        "kconfig_version": attr.string(
            doc = _KCONFIG_VERSION_DOC,
            default = DEFAULT_KCONFIG_VERSION,
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
        "write_invisible": attr.bool(
            doc = """\
Write the symbols the configuration makes invisible (no prompt applies and
no default does) too: to `rendered.config`, each in its place, as
`# CONFIG_X is not set` or with the type's empty value (`CONFIG_X=""`,
`CONFIG_X=0`), and to `config.h` as that value, so that a `string` or `int`
is defined, an empty one. The kernel's tools leave such a symbol out of
`.config` and `autoconf.h`, so that `#ifdef` can tell; for sources that
expect a `CONFIG_X` for every symbol, as BusyBox's `conf` writes it.
""",
            default = False,
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
    # The kernel's parser of each release, for building the parser; fetched
    # only when it is.
    for version in PARSER_VERSIONS:
        kernel_kconfig_repository(
            name = kernel_kconfig_repository_name(version),
            version = version,
        )

    # The parser's builds of this release the host can use, or the ones
    # `RULES_KCONFIG_WASM` and `RULES_KCONFIG_TOOL` name; fetched only when a
    # repository is generated with them, or `menuconfig` runs the native
    # build as its launcher. The repository is always declared, as
    # rules_kconfig's MODULE.bazel imports it for `menuconfig`.
    wasm_module = None
    tool = None
    location = parser_location(module_ctx)
    none = struct(url = None, integrity = "", path = None)
    wasm = location.wasm or none
    native = location.tool or none
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

            # Checked here, so that a version this release has no parser for
            # fails as the extension is evaluated.
            parser_version(tag.kconfig_version, "kconfig.repo `{}`".format(tag.name))

            kconfig_repository(
                name = tag.name,
                apparent_name = tag.name,
                defaults = tag.defaults,
                env = tag.env,
                env_labels = tag.env_labels,
                kconfig = tag.kconfig,
                kconfig_version = tag.kconfig_version,
                settings_labels = settings_labels,
                settings_options = tag.settings_options,
                tool = tool,
                write_invisible = tag.write_invisible,
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
        "repo": _REPO,
    },
)
