"""kconfig_overrides_repository rule for overlaying .config onto an external kconfig repo."""

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

def _inputs(repository_ctx):
    """What both backends read: the manifest of the source repository and the configs."""
    manifest_path = repository_ctx.path(repository_ctx.attr.kconfig)
    manifest = json.decode(repository_ctx.read(manifest_path))
    kconfig_srcs = manifest_path.dirname.get_child("kconfig_srcs")

    base_config_path = None
    base_config = manifest.get("config")
    if base_config:
        base_config_path = manifest_path.dirname.get_child(base_config)
        repository_ctx.watch(base_config_path)

    config_label = repository_ctx.attr.config
    return struct(
        manifest = manifest,
        kconfig_srcs = kconfig_srcs,
        kconfig_root = kconfig_srcs.get_child(manifest["root"]),
        kconfig_repo = str(repository_ctx.attr.kconfig).split("//")[0],
        config = repository_ctx.path(config_label),
        config_ws_path = (config_label.package + "/" + config_label.name).lstrip("/"),
        base_config = base_config_path,
        settings_labels = manifest.get("settings_labels") or {},
    )

def _generate_with_python(repository_ctx, inputs):
    """Run `overrides_gen.py` with the `interpreter`."""
    python = repository_ctx.path(repository_ctx.attr.interpreter)
    kconfiglib = _find_kconfiglib(repository_ctx)
    generator = repository_ctx.path(repository_ctx.attr._overrides_gen)
    repository_ctx.watch(generator)

    parser = repository_ctx.path(repository_ctx.attr._kconfig_parser)
    repository_ctx.watch(parser)

    cmd = [
        python,
        "-B",
        "-s",
        "-P",
        generator,
        "--kconfig",
        inputs.kconfig_root,
        "--srctree",
        inputs.kconfig_srcs,
        "--config",
        inputs.config,
        "--kconfig_repo",
        inputs.kconfig_repo,
        "--out_defs",
        repository_ctx.path("defs.bzl"),
        "--out_build",
        repository_ctx.path("BUILD.bazel"),
        "--out_rendered_config",
        repository_ctx.path("rendered.config"),
        "--config_ws_path",
        inputs.config_ws_path,
    ]

    if inputs.base_config:
        cmd.extend(["--base_config", inputs.base_config])

    if inputs.settings_labels:
        cmd.extend(["--settings_labels", json.encode(inputs.settings_labels)])

    rules_root = _rules_kconfig_root(repository_ctx)
    path_sep = ";" if "windows" in repository_ctx.os.name.lower() else ":"
    result = repository_ctx.execute(
        cmd,
        environment = {"PYTHONPATH": "{}{}{}".format(rules_root, path_sep, str(kconfiglib))},
    )
    if result.return_code != 0:
        fail("Failed to generate kconfig overrides: {}".format(result.stderr))

def _generate_with_wasm(repository_ctx, module, inputs):
    """Run the WebAssembly module, which reads the Kconfig tree through this rule."""
    request = new_request(repository_ctx, "overrides", inputs.kconfig_root, inputs.kconfig_srcs)
    request["config"] = str(inputs.config)
    request["base_config"] = str(inputs.base_config) if inputs.base_config else None
    request["kconfig_repo"] = inputs.kconfig_repo
    request["config_ws_path"] = inputs.config_ws_path
    request["settings_labels"] = dict(inputs.settings_labels)

    response = run_module(repository_ctx, module, request)
    write_files(repository_ctx, response["files"])

def _kconfig_overrides_repository_impl(repository_ctx):
    inputs = _inputs(repository_ctx)

    backend = select_backend(repository_ctx)
    if backend.name == "wasm":
        _generate_with_wasm(repository_ctx, backend.module, inputs)
    else:
        _generate_with_python(repository_ctx, inputs)

    repository_ctx.watch(inputs.config)

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
and wrapper rule that apply the overrides.

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
        "interpreter": attr.label(
            doc = "A Python interpreter target used to run the generator when the WebAssembly backend is not available.",
        ),
        "kconfig": attr.label(
            doc = "Label to the kconfig manifest from the source kconfig repository (e.g. `@my_kconfig//:my_kconfig`).",
            mandatory = True,
        ),
        "kconfiglib_anchor": attr.label(
            doc = "Label used to locate the `kconfiglib` package. Managed by the module extension.",
            mandatory = True,
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
        "_overrides_gen": attr.label(
            default = Label("//kconfig/private:overrides_gen.py"),
        ),
    },
)
