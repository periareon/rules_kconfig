"""make_variable_setting"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

def _make_variable_setting_impl(ctx):
    value = ctx.expand_make_variables("expression", ctx.attr.expression, {})
    kind = ctx.attr.type
    if kind == "string":
        return [BuildSettingInfo(value = value)]
    if kind == "int":
        if not value.lstrip("-").isdigit():
            fail("{}: `{}` expands to `{}`, which is not an int".format(
                ctx.label,
                ctx.attr.expression,
                value,
            ))
        return [BuildSettingInfo(value = int(value))]
    if not ctx.attr.equals:
        fail("{}: a `bool` setting needs `equals`".format(ctx.label))
    return [BuildSettingInfo(value = value == ctx.attr.equals)]

make_variable_setting = rule(
    doc = """\
A build setting whose value is a toolchain's "Make" variable, for `settings_labels`.

The variables come from the targets of the common `toolchains` attribute,
which provide `TemplateVariableInfo`: Bazel's C++ toolchain
(`@bazel_tools//tools/cpp:current_cc_toolchain`) has `CC`, `C_COMPILER`,
`LD`, `NM`, `OBJCOPY`, `STRIP` and more, rules_rust's
(`@rules_rust//rust/toolchain:current_rust_toolchain`) has `RUSTC`,
`RUSTDOC` and `CARGO`. The value is a string as expanded, an int, or a bool
that says whether the expansion `equals` a text:

```python
make_variable_setting(
    name = "cc",
    expression = "$(CC)",
    toolchains = ["@bazel_tools//tools/cpp:current_cc_toolchain"],
)

make_variable_setting(
    name = "cc_is_clang",
    equals = "clang",
    expression = "$(C_COMPILER)",
    toolchains = ["@bazel_tools//tools/cpp:current_cc_toolchain"],
    type = "bool",
)
```

Named in `settings_labels`, such a target gives a `CONFIG_*` symbol the
value of the toolchain Bazel resolved for the build, in `config.h` and the
transitions, where the repository rule saw only the variables of `env`. A
value that takes running the compiler (a `$(cc-option,...)` probe) is not a
Make variable; see the documentation on `env` for those.
""",
    implementation = _make_variable_setting_impl,
    attrs = {
        "equals": attr.string(
            doc = "For `type = \"bool\"`: the setting is true when the expansion is this text.",
        ),
        "expression": attr.string(
            doc = "The text to expand, with `$(NAME)` references to Make variables.",
            mandatory = True,
        ),
        "type": attr.string(
            doc = "The type of the setting: `string`, `int` or `bool`.",
            default = "string",
            values = ["string", "int", "bool"],
        ),
    },
    provides = [BuildSettingInfo],
)
