"""Rule for collecting Kconfig source files into a KConfigInfo provider."""

load(":kconfig_info.bzl", "KConfigInfo")

def _kconfig_library_impl(ctx):
    srcs = ctx.files.srcs

    # Generated sources will mean the repository rules don't work
    # so until a solution is found we ensure any sources are alway
    # real files and not action outputs
    generated = [src for src in srcs if not src.is_source]
    if generated:
        fail("`kconfig_library.srcs` does not allow generated files. Please update `{}` to remove: {}".format(
            ctx.label,
            generated,
        ))

    root = None
    if ctx.file.root:
        if ctx.file.root not in srcs:
            fail("{} is not tracked by `kconfig_library.srcs`. Please add `root` to that attribute for `{}`".format(
                ctx.file.root.path,
                ctx.label,
            ))
        root = ctx.file.root
    elif len(srcs) == 1:
        root = srcs[0]

    # What the tree reads, its dependencies' first and this library's over
    # them; the version is this library's, or the first a dependency names.
    transitive_srcs = []
    env = {}
    env_files = {}
    kconfig_version = ""
    for dep in ctx.attr.deps:
        dep_info = dep[KConfigInfo]
        transitive_srcs.append(dep_info.srcs)
        env.update(dep_info.env)
        env_files.update(dep_info.env_files)
        kconfig_version = kconfig_version or dep_info.kconfig_version
    env.update(ctx.attr.env)
    for label, name in ctx.attr.env_labels.items():
        files = label[DefaultInfo].files.to_list()
        if len(files) != 1:
            fail("`kconfig_library.env_labels` of `{}` maps `{}` to `{}`, which must be one file".format(
                ctx.label,
                label.label,
                name,
            ))
        env_files[name] = files[0]
    kconfig_version = ctx.attr.kconfig_version or kconfig_version

    all_srcs = depset(srcs, transitive = transitive_srcs)

    return [
        KConfigInfo(
            env = env,
            env_files = env_files,
            kconfig_version = kconfig_version,
            root = root,
            srcs = all_srcs,
        ),
        DefaultInfo(
            files = all_srcs,
            runfiles = ctx.runfiles(
                files = srcs + env_files.values(),
                transitive_files = depset(transitive = transitive_srcs),
            ),
        ),
    ]

kconfig_library = rule(
    doc = """\
Collect Kconfig source files into a single provider for use by `menuconfig` and repository rules.

All source files must be real (non-generated) files. If a single source is
provided, it is automatically treated as the root. When multiple sources are
present, set `root` explicitly to indicate the top-level Kconfig entry point.
Transitive sources from `deps` are included in the provider, as are their
variables; the library's own take precedence.

The release the tree is written for (`kconfig_version`) and the variables
its files read (`env`, `env_labels`) are properties of the tree, so they
live here, and `menuconfig` takes them from the provider. The `lib` of a
generated repository carries what its `kconfig.repo` was given.
""",
    implementation = _kconfig_library_impl,
    attrs = {
        "deps": attr.label_list(
            doc = "Other `kconfig_library` targets whose sources should be included transitively.",
            providers = [KConfigInfo],
        ),
        "env": attr.string_dict(
            doc = "Environment variables the Kconfig files read (`$(NAME)`, `option env`), by name.",
        ),
        "env_labels": attr.label_keyed_string_dict(
            doc = "Files whose path is a variable's value (a compiler the tree's `$(shell,...)` runs), each label mapped to the variable's name.",
            allow_files = True,
        ),
        "kconfig_version": attr.string(
            doc = "The kernel release the tree is written for, as `kconfig.repo` takes it (`6.12`, `4.19`); the newest checked when empty.",
        ),
        "root": attr.label(
            doc = "The top-level Kconfig file. Inferred automatically when `srcs` contains exactly one file.",
            allow_single_file = True,
        ),
        "srcs": attr.label_list(
            doc = "Kconfig source files, and any script their `$(shell,...)` commands run, so that `menuconfig` has them. Must be real (non-generated) files.",
            allow_files = True,
        ),
    },
    provides = [KConfigInfo],
)
