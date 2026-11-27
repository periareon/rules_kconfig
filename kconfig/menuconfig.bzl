"""menuconfig: the kernel's `mconf` over a Kconfig tree, by `bazel run`."""

load("//kconfig/private:versions.bzl", "DEFAULT_KCONFIG_VERSION", "PARSER_VERSIONS", "parser_version")
load("//kconfig/private/parser/kernel:repository.bzl", "kernel_kconfig_repository_name")
load(":kconfig_info.bzl", "KConfigInfo")

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

    # The mconf of the parser version that serves the release the tree is
    # written for, as the repository rule parses it: the same reading and
    # writing.
    version = parser_version(
        kconfig_info.kconfig_version or DEFAULT_KCONFIG_VERSION,
        "the kconfig_library of menuconfig {}".format(ctx.label),
    )
    mconf = None
    for target in ctx.attr._mconf:
        if target.label.repo_name.endswith(kernel_kconfig_repository_name(version)):
            mconf = target
    if mconf == None:
        fail("menuconfig: no mconf for parser version {}".format(version))
    mconf_binary = mconf[DefaultInfo].files_to_run.executable
    binary = ctx.executable._binary

    # Read by the launcher (//kconfig/private/menuconfig): the files by
    # runfiles path, and the tree's variables, a file's as its path.
    args = ctx.actions.args()
    args.add("--kconfig", _rlocationpath(kconfig_info.root, ctx.workspace_name))
    args.add("--mconf", _rlocationpath(mconf_binary, ctx.workspace_name))
    args.add("--config", ctx.attr.config)

    # The tree's variables are the library's with the target's over them: a
    # name the target sets is this run's, whether the library gave it a
    # value or a file.
    env = dict(kconfig_info.env)
    env.update(ctx.attr.env)
    env_files = {
        name: file
        for name, file in kconfig_info.env_files.items()
        if name not in ctx.attr.env
    }
    for name, value in env.items():
        args.add("--env", "{}={}".format(name, value))
    for name, file in env_files.items():
        args.add("--env-file", "{}={}".format(name, _rlocationpath(file, ctx.workspace_name)))
    args.set_param_file_format("multiline")

    args_file = ctx.actions.declare_file(ctx.label.name + ".args.txt")
    ctx.actions.write(
        output = args_file,
        content = args,
    )

    # The executable is the launcher itself under the target's name, so that
    # it finds the runfiles tree beside it by its argv[0] (`bazel run` unsets
    # RUNFILES_DIR), and takes the arguments from the file
    # RULES_KCONFIG_MENUCONFIG_ARGS_FILE names, on every platform alike.
    launcher = ctx.actions.declare_file("{}.{}".format(ctx.label.name, binary.extension).rstrip("."))
    ctx.actions.symlink(
        target_file = binary,
        output = launcher,
        is_executable = True,
    )

    runfiles = ctx.runfiles(files = [args_file, mconf_binary] + env_files.values())
    runfiles = runfiles.merge(ctx.attr.kconfig[DefaultInfo].default_runfiles)
    runfiles = runfiles.merge(ctx.attr._binary[DefaultInfo].default_runfiles)
    runfiles = runfiles.merge(mconf[DefaultInfo].default_runfiles)

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
Edit a `.config` interactively with `mconf`, the `make menuconfig` terminal UI.

`mconf` is built from the kernel's scripts/kconfig of the parser version
that serves the release the tree is written for (`kconfig_version` of its
`kconfig_library`), the code the kconfig repository rule reads the tree
with, so what the TUI accepts and writes is what the build reads. The tree's
variables (`env`, `env_labels` of the library) are set for it by a small
C++ launcher built from source, with the toolchain `mconf` needs anyway;
the target's `env` is set over them, for a variable of this run only.

`mconf` is a curses program over POSIX, so the target is for Linux and
macOS: on Windows it is incompatible, which `//...` skips and `bazel run`
reports.

Run with `bazel run`. The TUI reads and writes the file `config` names,
relative to the root module's workspace, which must exist there: the
launcher resolves the path on disk, and refuses one that leads outside the
workspace or to no file. A repository generated from a `defaults` file, or
`kconfig.overrides` over a `config`, has a `menuconfig` of its own over that
file when the file is the root module's.
""",
    implementation = _menuconfig_impl,
    executable = True,
    attrs = {
        "config": attr.string(
            doc = "Workspace-relative path of the `.config` file to read and write; an existing file of the root module's workspace.",
            mandatory = True,
        ),
        "env": attr.string_dict(
            doc = "Environment variables set for `mconf` over the library's (`env`, `env_labels`), by name: a tree variable for this target, or one `mconf` itself reads (`MENUCONFIG_COLOR`, `MENUCONFIG_MODE`).",
        ),
        "kconfig": attr.label(
            doc = "The `kconfig_library` of the tree: its files, release and variables.",
            mandatory = True,
            providers = [KConfigInfo],
        ),
        # The launcher and mconf run on the machine `bazel run` is on, whatever
        # `--platforms` the tree is built for: the execution configuration.
        "_binary": attr.label(
            default = Label("//kconfig/private/menuconfig"),
            executable = True,
            cfg = "exec",
        ),
        "_mconf": attr.label_list(
            default = [Label("@{}//:mconf".format(kernel_kconfig_repository_name(v))) for v in PARSER_VERSIONS],
            cfg = "exec",
        ),
    },
)
