"""Example rules providing BuildSettingInfo for use with setting_labels."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

def _fixed_int_setting_impl(ctx):
    return [BuildSettingInfo(value = ctx.attr.value)]

fixed_int_setting = rule(
    doc = """\
A rule that provides a fixed integer value as BuildSettingInfo.

In a real project this would resolve a toolchain and compute the value
at analysis time, e.g. by inspecting the CC toolchain for a compiler
version.
""",
    implementation = _fixed_int_setting_impl,
    attrs = {
        "value": attr.int(mandatory = True),
    },
    provides = [BuildSettingInfo],
)
