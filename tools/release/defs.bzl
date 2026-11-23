"""Release assets: `bazel run` targets that build in opt and publish.

A release attaches `kconfig.wasm` and a native build per platform,
`kconfig_tool-<os>-<cpu>[.exe]`, named as kconfig/private/parser/module.bzl
names them. Each is a `release_artifact` (see kconfig/private/parser's
BUILD): `bazel run` builds `src` in opt, for `platform` if one is given,
whatever the flags on the command line, and copies the result as `out` into
the directory named as the argument (by default the one `bazel run` was
invoked from). That replaces `bazel build -c opt` followed by `bazel cquery
--output=files` to learn where the build landed, which release_prep.sh and
release.yaml used to do, each in its own way.

The copying is `:publisher` (src/main.rs), a Rust program that finds the
asset through the runfiles library; the target's launcher is that program,
told what to publish through `RunEnvironmentInfo`.
"""

def _release_transition_impl(settings, attr):
    platforms = settings["//command_line_option:platforms"]
    if attr.platform:
        platforms = [str(attr.platform)]
    return {
        "//command_line_option:compilation_mode": "opt",
        "//command_line_option:platforms": platforms,
    }

_release_transition = transition(
    implementation = _release_transition_impl,
    inputs = ["//command_line_option:platforms"],
    outputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:platforms",
    ],
)

def _rlocationpath(file, workspace_name):
    if file.short_path.startswith("../"):
        return file.short_path[len("../"):]
    return "{}/{}".format(workspace_name, file.short_path)

def _release_artifact_impl(ctx):
    src = ctx.attr.src[0]
    executable = src[DefaultInfo].files_to_run.executable
    if executable:
        built = executable
    else:
        files = src[DefaultInfo].files.to_list()
        if len(files) != 1:
            fail("{} must build exactly one file to publish, not {}".format(src.label, files))
        built = files[0]

    # The asset under its published name, beside the launcher in bazel-bin
    # and in the runfiles, where the publisher finds it.
    out = ctx.actions.declare_file(ctx.attr.out)
    ctx.actions.symlink(
        output = out,
        target_file = built,
    )

    # The launcher is the publisher itself (src/main.rs), told what to
    # publish through the environment `bazel run` sets up.
    publisher = ctx.executable._publisher
    launcher = ctx.actions.declare_file("{}.{}".format(ctx.label.name, publisher.extension).rstrip("."))
    ctx.actions.symlink(
        output = launcher,
        target_file = publisher,
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [out])
    runfiles = runfiles.merge(ctx.attr._publisher[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(
            executable = launcher,
            files = depset([out]),
            runfiles = runfiles,
        ),
        RunEnvironmentInfo(
            environment = {
                "RULES_KCONFIG_RELEASE_ARTIFACT": _rlocationpath(out, ctx.workspace_name),
                "RULES_KCONFIG_RELEASE_EXECUTABLE": "1" if executable else "0",
            },
        ),
    ]

release_artifact = rule(
    doc = """\
A release asset: `bazel run` builds `src` in opt and copies it, as `out`, into
the directory given as the argument, by default the one `bazel run` was
invoked from. `bazel build` alone leaves `out` in bazel-bin, beside the
launcher.
""",
    implementation = _release_artifact_impl,
    executable = True,
    attrs = {
        "out": attr.string(
            doc = "The name the asset is published under.",
            mandatory = True,
        ),
        "platform": attr.label(
            doc = "The platform to build `src` for; the host's if unset.",
            providers = [platform_common.PlatformInfo],
        ),
        "src": attr.label(
            doc = "The target whose one output, or executable, is the asset.",
            mandatory = True,
            cfg = _release_transition,
        ),
        "_allowlist_function_transition": attr.label(
            default = Label("@bazel_tools//tools/allowlists/function_transition_allowlist"),
        ),
        "_publisher": attr.label(
            default = Label("//tools/release:publisher"),
            executable = True,
            cfg = "exec",
        ),
    },
)
