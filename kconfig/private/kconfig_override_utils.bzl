"""Shared rule and transition factories for kconfig overrides."""

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_cc_autoconf//autoconf:cc_autoconf_info.bzl", "CcAutoconfInfo")

def _forward_extra_providers(target):
    """Collect non-DefaultInfo providers to forward from a transitioned target."""
    providers = []
    if CcInfo in target:
        providers.append(target[CcInfo])
    if CcAutoconfInfo in target:
        providers.append(target[CcAutoconfInfo])
    if OutputGroupInfo in target:
        providers.append(target[OutputGroupInfo])
    if InstrumentedFilesInfo in target:
        providers.append(target[InstrumentedFilesInfo])
    return providers

def _with_kconfig_overrides_impl(ctx):
    """Forward providers from a target that has been transitioned with overrides."""
    target = ctx.attr.actual[0]
    providers = [target[DefaultInfo]] if DefaultInfo in target else []
    return providers + _forward_extra_providers(target)

def _with_kconfig_overrides_binary_impl(ctx):
    """Forward providers from an executable target that has been transitioned with overrides."""
    target = ctx.attr.actual[0]
    info = target[DefaultInfo]

    out = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(
        output = out,
        target_file = info.files_to_run.executable,
        is_executable = True,
    )

    providers = [DefaultInfo(
        executable = out,
        files = info.files,
        runfiles = info.default_runfiles,
    )]
    return providers + _forward_extra_providers(target)

def make_kconfig_override_transition(original_defaults, overrides):
    """Create a transition that applies kconfig overrides.

    Only flags whose current value matches *original_defaults* are
    overridden, so explicit command-line values take precedence.

    Args:
        original_defaults: ``dict[str, bool | int | str]`` mapping canonical
            flag labels to their original default values.
        overrides: ``dict[str, bool | int | str]`` mapping canonical flag
            labels to the desired override values.

    Returns:
        A ``transition`` object suitable for ``make_kconfig_overrides_rules``.
    """
    flags = list(original_defaults.keys())

    def _impl(settings, _attr):
        result = dict(settings)
        for flag, override in overrides.items():
            if settings[flag] == original_defaults[flag]:
                result[flag] = override
        return result

    return transition(
        implementation = _impl,
        inputs = flags,
        outputs = flags,
    )

def make_kconfig_overrides_rules(cfg):
    """Create ``with_kconfig_overrides`` rules wired to the given transition.

    Returns a pair of rules: one for non-executable targets (libraries,
    genrules, filegroups) and one for executable targets (binaries).
    Use the generated ``with_kconfig_overrides`` macro which delegates
    to the appropriate rule based on the ``executable`` parameter.

    Args:
        cfg: A ``transition`` object that maps kconfig flags to their
            overridden values.

    Returns:
        A tuple ``(non_executable_rule, executable_rule)``.
    """
    _attrs = {
        "actual": attr.label(
            doc = "The kconfig-dependent target to apply overrides to.",
            allow_files = True,
            cfg = cfg,
            mandatory = True,
        ),
        "_allowlist_function_transition": attr.label(
            default = Label("@bazel_tools//tools/allowlists/function_transition_allowlist"),
        ),
    }

    _non_exec = rule(
        doc = "Apply .config overrides to a kconfig-dependent target via a transition.",
        implementation = _with_kconfig_overrides_impl,
        attrs = _attrs,
    )

    _exec = rule(
        doc = "Apply .config overrides to a kconfig-dependent executable target via a transition.",
        implementation = _with_kconfig_overrides_binary_impl,
        executable = True,
        attrs = _attrs,
    )

    return _non_exec, _exec
