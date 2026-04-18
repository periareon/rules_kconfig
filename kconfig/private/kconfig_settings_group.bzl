"""A rule that aggregates kconfig build settings into a single target."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

KconfigSettingsInfo = provider(
    doc = "Aggregates BuildSettingInfo from all CONFIG_* flags in a kconfig repository.",
    fields = {
        "settings": "dict[str, BuildSettingInfo]: Maps CONFIG_* names to their BuildSettingInfo.",
    },
)

def _kconfig_settings_group_impl(ctx):
    settings = {}
    for setting in ctx.attr.settings:
        settings[setting.label.name] = setting[BuildSettingInfo]

    return [KconfigSettingsInfo(settings = settings)]

kconfig_settings_group = rule(
    doc = "Collects all CONFIG_* build settings into a single KconfigSettingsInfo provider.",
    implementation = _kconfig_settings_group_impl,
    attrs = {
        "settings": attr.label_list(
            doc = "The `CONFIG_*` build setting targets to read.",
            providers = [BuildSettingInfo],
            mandatory = True,
        ),
    },
    provides = [KconfigSettingsInfo],
)
