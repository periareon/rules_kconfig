"""A rule that launches kconfiglib's menuconfig TUI for interactive Kconfig editing."""

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
    binary = ctx.executable._binary
    binary_target = ctx.attr._binary[0]

    args = ctx.actions.args()
    args.add("--kconfig", ctx.file.kconfig.short_path)
    args.add("--defaults", ctx.attr.defaults)
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

    runfiles = ctx.runfiles(files = [args_file, ctx.file.kconfig])
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
the path specified by `defaults` (relative to the workspace root).
""",
    implementation = _menuconfig_impl,
    executable = True,
    attrs = {
        "defaults": attr.string(
            doc = "Workspace-relative path to the `.config` file to read/write.",
            default = ".config",
        ),
        "kconfig": attr.label(
            doc = "The root Kconfig file to parse.",
            mandatory = True,
            allow_single_file = True,
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
