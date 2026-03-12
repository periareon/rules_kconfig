"""Shared rule and transition factories for kconfig overrides."""

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_cc_autoconf//autoconf:cc_autoconf_info.bzl", "CcAutoconfInfo")

def _with_kconfig_overrides_impl(ctx):
    """Forward providers from a target that has been transitioned with overrides."""
    target = ctx.attr.actual[0]
    providers = []
    if DefaultInfo in target:
        providers.append(target[DefaultInfo])
    if CcInfo in target:
        providers.append(target[CcInfo])
    if CcAutoconfInfo in target:
        providers.append(target[CcAutoconfInfo])
    if OutputGroupInfo in target:
        providers.append(target[OutputGroupInfo])
    if InstrumentedFilesInfo in target:
        providers.append(target[InstrumentedFilesInfo])
    return providers

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
        A ``transition`` object suitable for ``make_kconfig_overrides_rule``.
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

def make_kconfig_overrides_rule(cfg):
    """Create a ``with_kconfig_overrides`` rule wired to the given transition.

    Args:
        cfg: A ``transition`` object that maps kconfig flags to their
            overridden values.

    Returns:
        A Bazel ``rule`` whose ``actual`` attribute applies *cfg* before
        forwarding providers from the underlying target.
    """
    return rule(
        doc = "Apply .config overrides to a kconfig-dependent target via a transition.",
        implementation = _with_kconfig_overrides_impl,
        attrs = {
            "actual": attr.label(
                doc = "The kconfig-dependent target to apply overrides to.",
                allow_files = True,
                cfg = cfg,
                mandatory = True,
            ),
            "_allowlist_function_transition": attr.label(
                default = Label("@bazel_tools//tools/allowlists/function_transition_allowlist"),
            ),
        },
    )
