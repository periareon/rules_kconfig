"""kconfig_savedefconfig"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

def _format_bool(name, value):
    if value:
        return "{}=y".format(name)
    return "# {} is not set".format(name)

def _format_int(name, value):
    return "{}={}".format(name, value)

def _format_string(name, value):
    if not value:
        return "# {} is not set".format(name)
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return '{}="{}"'.format(name, escaped)

def _kconfig_savedefconfig_impl(ctx):
    lines = []
    defaults = ctx.attr.defaults

    for setting in ctx.attr.settings:
        info = setting[BuildSettingInfo]
        name = setting.label.name
        value = info.value
        default_str = defaults.get(name, "")

        if type(value) == "bool":
            default_val = default_str == "True"
            if value != default_val:
                lines.append(_format_bool(name, value))
        elif type(value) == "int":
            default_val = int(default_str) if default_str else 0
            if value != default_val:
                lines.append(_format_int(name, value))
        elif type(value) == "string":
            if value != default_str:
                if value:
                    lines.append(_format_string(name, value))
                else:
                    lines.append("# {} is not set".format(name))
        else:
            fail("Unsupported build setting type for {}: {}".format(name, type(value)))

    output = ctx.actions.declare_file(ctx.attr.out)
    ctx.actions.write(
        output = output,
        content = "\n".join(lines) + "\n" if lines else "",
    )

    return [DefaultInfo(files = depset([output]))]

kconfig_savedefconfig = rule(
    doc = """\
A rule that generates a minimal .config (defconfig) from Kconfig build settings.

Only symbols whose current value differs from the Kconfig default are written,
producing a sparse config suitable for `conf -D` (olddefconfig).
""",
    implementation = _kconfig_savedefconfig_impl,
    attrs = {
        "defaults": attr.string_dict(
            doc = "Map of CONFIG_* names to their Kconfig default values as strings.",
        ),
        "out": attr.string(
            default = "defconfig",
            doc = "Output filename for the generated config.",
        ),
        "settings": attr.label_list(
            doc = "The CONFIG_* build setting targets to read.",
            providers = [BuildSettingInfo],
        ),
    },
)
