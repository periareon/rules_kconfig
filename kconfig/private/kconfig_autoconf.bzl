"""A rule that bridges Kconfig build settings to CcAutoconfInfo."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_cc_autoconf//autoconf:cc_autoconf_info.bzl", "CcAutoconfInfo")

def _kconfig_autoconf_impl(ctx):
    define_results = {}

    for setting in ctx.attr.settings:
        info = setting[BuildSettingInfo]
        name = setting.label.name
        value = info.value

        if type(value) == "bool":
            if not value:
                continue
            json_value = "1"
        elif type(value) == "int":
            json_value = str(value)
        elif type(value) == "string":
            if not value:
                continue
            json_value = json.encode(value)
        else:
            fail("Unsupported build setting type for {}: {}".format(name, type(value)))

        result_file = ctx.actions.declare_file("{}/{}.result.json".format(ctx.label.name, name))
        ctx.actions.write(
            output = result_file,
            content = json.encode_indent({
                name: {
                    "define": name,
                    "is_define": True,
                    "success": True,
                    "type": "define",
                    "value": json_value,
                },
            }, indent = "    ") + "\n",
        )
        define_results[name] = result_file

    return [
        CcAutoconfInfo(
            owner = ctx.label,
            deps = depset(),
            cache_results = {},
            define_results = define_results,
            subst_results = {},
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
