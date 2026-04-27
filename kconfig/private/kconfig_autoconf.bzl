"""A rule that bridges Kconfig build settings to CcAutoconfInfo."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_cc_autoconf//autoconf:cc_autoconf_info.bzl", "CcAutoconfInfo", "encode_result")

def _is_unquoted_value(value):
    """Return True if a string value should be rendered unquoted in C."""
    if not value:
        return False
    if value.startswith("0x") or value.startswith("0X"):
        return True
    if value.lstrip("-").isdigit():
        return True
    return False

def _kconfig_autoconf_impl(ctx):
    define_results = {}
    unquoted = []

    for setting in ctx.attr.settings:
        info = setting[BuildSettingInfo]
        name = setting.label.name
        value = info.value

        if type(value) == "bool":
            if not value:
                continue
            result_value = 1
        elif type(value) == "int":
            result_value = value
        elif type(value) == "string":
            if not value or value == "n":
                continue
            if value == "y":
                result_value = 1
            else:
                result_value = value
                if _is_unquoted_value(value):
                    unquoted.append(name)
        else:
            fail("Unsupported build setting type for {}: {}".format(name, type(value)))

        result_file = ctx.actions.declare_file("{}/{}.result.json".format(ctx.label.name, name))
        ctx.actions.write(
            output = result_file,
            content = encode_result(result_value),
        )
        define_results[name] = result_file

    return [
        CcAutoconfInfo(
            owner = ctx.label,
            define_results = define_results,
            unquoted_defines = unquoted,
        ),
    ]

kconfig_autoconf = rule(
    doc = "Reads Kconfig build setting flag values and produces CcAutoconfInfo for use with autoconf_hdr.",
    implementation = _kconfig_autoconf_impl,
    attrs = {
        "settings": attr.label_list(
            doc = "The CONFIG_* build setting targets to read.",
            providers = [BuildSettingInfo],
        ),
    },
    provides = [CcAutoconfInfo],
)
