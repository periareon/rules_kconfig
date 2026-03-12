"""kconfig_toolchain_alias"""

load("@rules_venv//python:py_info.bzl", "PyInfo")

TOOLCHAIN_TYPE = str(Label("//kconfig:toolchain_type"))

def _kconfig_toolchain_alias_impl(ctx):
    toolchain = ctx.toolchains[TOOLCHAIN_TYPE]

    target = toolchain.kconfiglib

    # For some reason, simply forwarding `DefaultInfo` from
    # the target results in a loss of data. To avoid this a
    # new provider is created with teh same info.
    default_info = DefaultInfo(
        files = target[DefaultInfo].files,
        runfiles = target[DefaultInfo].default_runfiles,
    )

    return [
        toolchain,
        default_info,
        target[PyInfo],
        target[OutputGroupInfo],
        target[InstrumentedFilesInfo],
    ]

kconfig_toolchain_alias = rule(
    doc = "A rule for exposing the current registered `kconfig_toolchain`.",
    implementation = _kconfig_toolchain_alias_impl,
    toolchains = [TOOLCHAIN_TYPE],
)
