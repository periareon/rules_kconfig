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

    transitive_srcs = []
    for dep in ctx.attr.deps:
        dep_info = dep[KConfigInfo]
        transitive_srcs.append(dep_info.srcs)

    all_srcs = depset(srcs, transitive = transitive_srcs)

    return [
        KConfigInfo(
            root = root,
            srcs = all_srcs,
        ),
        DefaultInfo(
            files = all_srcs,
            runfiles = ctx.runfiles(
                files = srcs,
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
Transitive sources from `deps` are included in the provider.
""",
    implementation = _kconfig_library_impl,
    attrs = {
        "deps": attr.label_list(
            doc = "Other `kconfig_library` targets whose sources should be included transitively.",
            providers = [KConfigInfo],
        ),
        "root": attr.label(
            doc = "The top-level Kconfig file. Inferred automatically when `srcs` contains exactly one file.",
            allow_single_file = True,
        ),
        "srcs": attr.label_list(
            doc = "Kconfig source files. Must be real (non-generated) files.",
            allow_files = True,
        ),
    },
    provides = [KConfigInfo],
)
