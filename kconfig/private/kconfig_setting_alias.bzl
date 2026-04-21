"""A rule that forwards BuildSettingInfo from another target while preserving its own label name."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

def _kconfig_setting_alias_impl(ctx):
    return [ctx.attr.actual[BuildSettingInfo]]

kconfig_setting_alias = rule(
    doc = "Forwards BuildSettingInfo from ``actual``, preserving this target's label name for consumers like kconfig_autoconf.",
    implementation = _kconfig_setting_alias_impl,
    attrs = {
        "actual": attr.label(
            doc = "The target providing BuildSettingInfo.",
            providers = [BuildSettingInfo],
            mandatory = True,
        ),
    },
    provides = [BuildSettingInfo],
)
