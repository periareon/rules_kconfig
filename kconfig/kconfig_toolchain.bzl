"""Kconfig toolchain backed by kconfiglib."""

load("@rules_venv//python:py_info.bzl", "PyInfo")

def _kconfig_toolchain_impl(ctx):
    return [platform_common.ToolchainInfo(
        kconfiglib = ctx.attr.kconfiglib,
    )]

kconfig_toolchain = rule(
    doc = "Declares a kconfig toolchain backed by kconfiglib.",
    implementation = _kconfig_toolchain_impl,
    attrs = {
        "kconfiglib": attr.label(
            doc = "A py_library providing kconfiglib.",
            mandatory = True,
            providers = [PyInfo],
        ),
    },
)
