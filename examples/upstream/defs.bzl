"""A generated repository checked against the tree's own `conf`.

`conf_config` runs the `scripts/kconfig/conf` built from the tree the way
`make <defconfig>` or `make alldefconfig` does, in the tree's directory and
with the variables its Makefile exports, and `kconfig_conf_test` compares the
`.config` it writes with the `rendered.config` of the repository rules_kconfig
generated from the same tree, defaults file and variables.
"""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("@bazel_skylib//rules:diff_test.bzl", "diff_test")

def conf_config(*, name, conf, kconfig, srcs, env, defconfig = None, **kwargs):
    """The `.config` the tree's `conf` writes.

    Args:
        name: The name of the target; the file is `<name>.config`.
        conf: The tree's `scripts/kconfig/conf`, built from the tree.
        kconfig: The tree's root Kconfig; `conf` runs in its directory.
        srcs: What `conf` reads: the Kconfig files and the scripts they run.
        env: The variables the tree's Makefile exports to Kconfig.
        defconfig: A defconfig to start from (`conf --defconfig`); without
            one every symbol takes its default (`conf --alldefconfig`).
        **kwargs: Common attributes for the `genrule`.
    """
    exports = " ".join([
        "{}={}".format(variable, shell.quote(value))
        for variable, value in sorted(env.items())
    ])
    if defconfig:
        before = 'defconfig="$$PWD/$(execpath {})"'.format(defconfig)
        mode = '--defconfig="$$defconfig"'
    else:
        before = ":"
        mode = "--alldefconfig"
    native.genrule(
        name = name,
        srcs = [kconfig, srcs] + ([defconfig] if defconfig else []),
        outs = [name + ".config"],
        cmd = """
set -e
out="$$PWD/$@"
conf="$$PWD/$(execpath {conf})"
{before}
cd "$$(dirname "$(execpath {kconfig})")"
export {exports} srctree=. KCONFIG_CONFIG="$$out"
"$$conf" {mode} Kconfig > /dev/null
""".format(
            before = before,
            conf = conf,
            exports = exports,
            kconfig = kconfig,
            mode = mode,
        ),
        tools = [conf],
        **kwargs
    )

def config_values(*, name, src, **kwargs):
    """The `CONFIG_<name>=<value>` lines of a `.config`, for comparing two.

    Everything else a `.config` has is left out: the heading, the menu
    comments (U-Boot's older kconfig writes no `# end of` lines) and the
    `# CONFIG_<name> is not set` lines, as which symbols at `n` a release of
    kconfig chooses to write has changed between the kernel's parser of 6.9,
    which rules_kconfig builds on, and later ones (6.12 lists an `imply`'d
    symbol the earlier one leaves out). A symbol wrongly on or off still
    shows: its `CONFIG_<name>=` line is then on one side only.

    Args:
        name: The name of the target; the file is `<name>.txt`.
        src: The `.config`.
        **kwargs: Common attributes for the `genrule`.
    """
    native.genrule(
        name = name,
        srcs = [src],
        outs = [name + ".txt"],
        cmd = "grep -E '^CONFIG_' $< > $@",
        **kwargs
    )

def kconfig_conf_test(*, name, repo, conf, kconfig, srcs, env, defconfig = None, **kwargs):
    """A test that a generated repository's `rendered.config` is the tree's own.

    Args:
        name: The name of the test.
        repo: The repository `kconfig.repo` generated from the tree with
            `defconfig` as its defaults file and `env` as its variables, as
            `@name`.
        conf: As `conf_config`.
        kconfig: As `conf_config`.
        srcs: As `conf_config`.
        env: As `conf_config`.
        defconfig: As `conf_config`.
        **kwargs: Common attributes for the test.
    """
    conf_config(
        name = name + "_conf",
        conf = conf,
        defconfig = defconfig,
        env = env,
        kconfig = kconfig,
        srcs = srcs,
    )
    config_values(
        name = name + "_conf_values",
        src = ":" + name + "_conf",
    )
    config_values(
        name = name + "_values",
        src = repo + "//:rendered.config",
    )
    diff_test(
        name = name,
        failure_message = "{}//:rendered.config does not have the values the tree's own `conf` writes".format(repo),
        file1 = ":" + name + "_conf_values",
        file2 = ":" + name + "_values",
        **kwargs
    )
