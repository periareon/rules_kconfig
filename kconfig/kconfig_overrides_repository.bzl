"""kconfig_overrides_repository rule for overlaying .config onto an external kconfig repo."""

load(
    "//kconfig/private:parser_backend.bzl",
    "host_independent",
    "new_request",
    "run_parser",
    "seed_file",
    "select_backend",
    "write_files",
)
load("//kconfig/private:versions.bzl", "DEFAULT_KCONFIG_VERSION", "parser_version")

def _inputs(repository_ctx):
    """What the parser reads: the manifest of the source repository and the configs."""
    manifest_path = repository_ctx.path(repository_ctx.attr.kconfig)
    manifest = json.decode(repository_ctx.read(manifest_path))
    kconfig_srcs = manifest_path.dirname.get_child("kconfig_srcs")

    # The tree where the source repository read it, so that the files and
    # the paths the probes' commands name are the same as its manifest
    # records them; a manifest of a release before it names no tree, and the
    # Kconfig files linked under kconfig_srcs/ stand in.
    srctree = manifest.get("srctree")
    srctree = repository_ctx.path(srctree) if srctree else kconfig_srcs

    # The version the source repository was generated with; a manifest of a
    # release before versions is of the default.
    kconfig_version = manifest.get("kconfig_version") or DEFAULT_KCONFIG_VERSION

    base_config_path = None
    base_config = manifest.get("config")
    if base_config:
        base_config_path = manifest_path.dirname.get_child(base_config)
        repository_ctx.watch(base_config_path)

    config_label = repository_ctx.attr.config
    return struct(
        manifest = manifest,
        srctree = srctree,
        kconfig_root = srctree.get_child(manifest["root"]),
        kconfig_repo = str(repository_ctx.attr.kconfig).split("//")[0],
        config = repository_ctx.path(config_label),
        # For the generated `menuconfig`, which edits a file of the root
        # module's workspace only: None for a file of another repository.
        config_ws_path = (config_label.package + "/" + config_label.name).lstrip("/") if config_label.repo_name == "" else None,
        base_config = base_config_path,
        settings_labels = manifest.get("settings_labels") or {},
        # The variables the source repository gave the tree, its version,
        # what the tree's `$(shell,...)` commands answered and whether it
        # writes the invisible symbols; it is parsed again with them.
        env = manifest.get("env") or {},
        kconfig_version = kconfig_version,
        shell = manifest.get("shell") or {},
        write_invisible = manifest.get("write_invisible", False),
        parser_version = parser_version(kconfig_version, "the manifest of " + str(repository_ctx.attr.kconfig)),
    )

def _generate_with_parser(repository_ctx, backend, inputs):
    """Run the parser, which reads the Kconfig tree through this rule."""
    request = new_request(repository_ctx, "overrides", inputs.kconfig_root, inputs.srctree, env = inputs.env)
    request["config"] = str(inputs.config)
    request["base_config"] = str(inputs.base_config) if inputs.base_config else None
    request["kconfig_repo"] = inputs.kconfig_repo
    request["config_ws_path"] = inputs.config_ws_path
    request["settings_labels"] = dict(inputs.settings_labels)
    request["kconfig_version"] = inputs.kconfig_version
    request["parser_version"] = inputs.parser_version
    request["write_invisible"] = inputs.write_invisible
    seed_file(repository_ctx, request, inputs.config)
    if inputs.base_config:
        seed_file(repository_ctx, request, inputs.base_config)

    # The probes answer as they did for the source repository: the
    # configuration is the source's with other values, not another host's
    # probes.
    for command, stdout in inputs.shell.items():
        request["shell"][command] = {"stdout": stdout}

    response = run_parser(repository_ctx, backend, request, env = inputs.env)
    write_files(repository_ctx, response["files"])
    return host_independent(request, replayed = inputs.shell)

def _kconfig_overrides_repository_impl(repository_ctx):
    inputs = _inputs(repository_ctx)

    reproducible = _generate_with_parser(repository_ctx, select_backend(repository_ctx), inputs)

    repository_ctx.watch(inputs.config)

    repository_ctx.file("WORKSPACE.bazel", """workspace(name = "{}")""".format(
        repository_ctx.name,
    ))

    # As in `kconfig_repository`: a reproducible repository may come from the
    # repo contents cache.
    if reproducible and hasattr(repository_ctx, "repo_metadata"):
        return repository_ctx.repo_metadata(reproducible = True)
    return None

kconfig_overrides_repository = repository_rule(
    doc = """\
Overlay .config values onto an existing kconfig repository.

Reads the manifest from the source kconfig repository to locate the
Kconfig tree, then reparses it where the source repository read it, with the
parser of the `kconfig_version` the manifest records, as `kconfig_repository`
did, with a user-provided `.config` file. If the source repository was itself
created with a `.config`, the overrides are stacked on top of those
base values. The tree's `$(shell,...)` commands answer as they did for the
source repository, from its manifest, and `rendered.config` is written as
the source repository's was (`write_invisible`). Generates a `defs.bzl`
containing a Starlark transition and wrapper rule that apply the overrides.

Values explicitly set on the command line take precedence over the overlay.

The generated `defs.bzl` creates the transition and rule:

| rule | description |
| --- | --- |
| `kconfig_override_transition` | A transition that applies transitions for each default in `.config` |
| `with_kconfig_overrides` | A rule similar to [`alias`](https://bazel.build/reference/be/general#alias) that applies `kconfig_override_transition` to the target |

Use `with_kconfig_overrides` to wrap a kconfig-dependent target:

```python
load("@base_kconfig_override//:defs.bzl", "with_kconfig_overrides")

with_kconfig_overrides(
    name = "config",
    actual = ":consumer_of_base",
)
```
""",
    implementation = _kconfig_overrides_repository_impl,
    attrs = {
        "config": attr.label(
            doc = ".config file with override values.",
            mandatory = True,
        ),
        "kconfig": attr.label(
            doc = "Label to the kconfig manifest from the source kconfig repository (e.g. `@my_kconfig//:my_kconfig`).",
            mandatory = True,
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
