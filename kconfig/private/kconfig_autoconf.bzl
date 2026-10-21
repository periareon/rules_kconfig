"""A rule that bridges Kconfig build settings to CcAutoconfInfo."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_cc_autoconf//autoconf:cc_autoconf_info.bzl", "CcAutoconfInfo", "encode_result")

def _is_unquoted_value(value):
    """Return True if a string value should be rendered unquoted in C.

    The guess for settings whose Kconfig type is not known.
    """
    if not value:
        return False
    if value.startswith("0x") or value.startswith("0X"):
        return True
    if value.lstrip("-").isdigit():
        return True
    return False

def _define(name, value, kconfig_type):
    """What a setting defines, as the Kconfig tools write `autoconf.h`.

    Args:
        name: The `CONFIG_*` name of the setting.
        value: The build setting's value.
        kconfig_type: `bool`, `tristate`, `int`, `hex` or `string`; None to guess.

    Returns:
        tuple: The define's name, its value and whether it is unquoted, or
            None when the setting defines nothing (`n`, an unset string).
    """
    if kconfig_type == None:
        # Older generated repositories do not record types.
        if type(value) == "bool":
            return (name, 1, True) if value else None
        if type(value) == "int":
            return (name, value, True)
        if not value or value == "n":
            return None
        if value == "y":
            return (name, 1, True)
        return (name, value, _is_unquoted_value(value))

    if kconfig_type == "bool":
        return (name, 1, True) if value else None
    if kconfig_type == "tristate":
        if value == "y":
            return (name, 1, True)
        if value == "m":
            return (name + "_MODULE", 1, True)
        return None
    if kconfig_type == "int":
        return (name, value, True)
    if kconfig_type == "hex":
        if not value:
            return None
        if not (value.startswith("0x") or value.startswith("0X")):
            value = "0x" + value
        return (name, value, True)
    if kconfig_type == "string":
        if not value:
            return None
        return (name, value, False)
    fail("Unknown Kconfig type for {}: {}".format(name, kconfig_type))

def _kconfig_autoconf_impl(ctx):
    define_results = {}
    unquoted = []

    for setting in ctx.attr.settings:
        info = setting[BuildSettingInfo]
        name = setting.label.name
        value = info.value
        if type(value) not in ("bool", "int", "string"):
            fail("Unsupported build setting type for {}: {}".format(name, type(value)))

        define = _define(name, value, ctx.attr.types.get(name))
        if define == None:
            continue
        define_name, define_value, is_unquoted = define
        if is_unquoted:
            unquoted.append(define_name)

        result_file = ctx.actions.declare_file("{}/{}.result.json".format(ctx.label.name, define_name))
        ctx.actions.write(
            output = result_file,
            content = encode_result(define_value),
        )
        define_results[define_name] = result_file

    return [
        CcAutoconfInfo(
            owner = ctx.label,
            define_results = define_results,
            unquoted_defines = unquoted,
        ),
    ]

kconfig_autoconf = rule(
    doc = """\
Reads Kconfig build setting flag values and produces CcAutoconfInfo for use with autoconf_hdr.

The defines follow the Kconfig tools' `autoconf.h`: `bool` and `tristate` `y`
define `CONFIG_X 1`, `tristate` `m` defines `CONFIG_X_MODULE 1`, `int` and
`hex` are unquoted (hex with its `0x` prefix), `string` is quoted, and `n` or
an empty string defines nothing.
""",
    implementation = _kconfig_autoconf_impl,
    attrs = {
        "settings": attr.label_list(
            doc = "The CONFIG_* build setting targets to read.",
            providers = [BuildSettingInfo],
        ),
        "types": attr.string_dict(
            doc = "The Kconfig type of each setting (`bool`, `tristate`, `int`, `hex`, `string`), by `CONFIG_*` name. A setting without one is rendered by the look of its value.",
            default = {},
        ),
    },
    provides = [CcAutoconfInfo],
)
