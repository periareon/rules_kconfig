"""menuconfig"""

load(":kconfig_info.bzl", "KConfigInfo")

def _opt_transition_impl(_settings, _attr):
    return {"//command_line_option:compilation_mode": "opt"}

_opt_transition = transition(
    implementation = _opt_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:compilation_mode"],
)

def _rlocationpath(file, workspace_name):
    if file.short_path.startswith("../"):
        return file.short_path[len("../"):]

    return "{}/{}".format(workspace_name, file.short_path)

def _menuconfig_impl(ctx):
    kconfig_info = ctx.attr.kconfig[KConfigInfo]
    if not kconfig_info.root:
        fail("menuconfig requires a kconfig_library with a root Kconfig file, but {} has no root set".format(
            ctx.attr.kconfig.label,
        ))

    binary = ctx.executable._binary
    binary_target = ctx.attr._binary[0]

    args = ctx.actions.args()
    args.add("--kconfig", _rlocationpath(kconfig_info.root, ctx.workspace_name))
    args.add("--config", ctx.attr.config)
    args.set_param_file_format("multiline")

    args_file = ctx.actions.declare_file(ctx.label.name + ".args.txt")
    ctx.actions.write(
        output = args_file,
        content = args,
    )

    launcher = ctx.actions.declare_file("{}.{}".format(ctx.label.name, binary.extension).rstrip("."))
    ctx.actions.symlink(
        target_file = binary,
        output = launcher,
        is_executable = True,
    )

    runfiles = ctx.runfiles(files = [args_file])
    runfiles = runfiles.merge(ctx.attr.kconfig[DefaultInfo].default_runfiles)
    runfiles = runfiles.merge(binary_target[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(
            executable = launcher,
            runfiles = runfiles,
        ),
        RunEnvironmentInfo(
            environment = {
                "RULES_KCONFIG_MENUCONFIG_ARGS_FILE": _rlocationpath(args_file, ctx.workspace_name),
            },
        ),
    ]

menuconfig = rule(
    doc = """\
Launch kconfiglib's menuconfig TUI for interactive Kconfig editing.

Run with `bazel run` to interactively create or edit a `.config` file
against a Kconfig tree. The TUI writes the resulting configuration to
the path specified by `config` (relative to the workspace root).
""",
    implementation = _menuconfig_impl,
    executable = True,
    attrs = {
        "config": attr.string(
            doc = "Workspace-relative path to the `.config` file to read/write.",
            mandatory = True,
        ),
        "kconfig": attr.label(
            doc = "A kconfig_library target providing the Kconfig source tree.",
            mandatory = True,
            providers = [KConfigInfo],
        ),
        "_allowlist_function_transition": attr.label(
            default = Label("@bazel_tools//tools/allowlists/function_transition_allowlist"),
        ),
        "_binary": attr.label(
            default = Label("//kconfig/private:menuconfig_runner"),
            executable = True,
            cfg = _opt_transition,
        ),
    },
)
