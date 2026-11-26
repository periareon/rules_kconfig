"""A generated repository checked against the tree's own `conf`.

`conf_config` runs the `scripts/kconfig/conf` built from the tree the way
`make <defconfig>` or `make alldefconfig` does, in the tree's directory and
with the variables its Makefile exports, and `kconfig_conf_test` compares the
`.config` it writes, whole but for its heading, with the `rendered.config` of
the repository rules_kconfig generated from the same tree, defaults file and
variables, with the parser of the tree's `kconfig_version`.
"""

load("@bazel_skylib//rules:diff_test.bzl", "diff_test")
load("@bazel_skylib//rules:run_binary.bzl", "run_binary")

def conf_config(*, name, conf, kconfig, srcs, env, defconfig = None, old_conf = False, **kwargs):
    """The `.config` the tree's `conf` writes, and the same without its heading.

    `conf_config.sh` runs `conf`; the files are `<name>.config` and
    `<name>_body.txt`, the latter without the four lines naming the tree and
    its version (`# Linux/x86 6.12.0 Kernel Configuration`), which
    `rendered.config` has no counterpart to. Everything else, the values, the
    `# CONFIG_<name> is not set` lines and the menu comments, is compared as
    the tree's own `conf` of the same kernel release writes it.

    Args:
        name: The name of the target.
        conf: The tree's `scripts/kconfig/conf`, built from the tree.
        kconfig: The tree's root Kconfig; `conf` runs in its directory.
        srcs: What `conf` reads: the Kconfig files and the scripts they run.
        env: The variables the tree's Makefile exports to Kconfig.
        defconfig: A defconfig to start from (`conf --defconfig`); without
            one every symbol takes its default (`conf --alldefconfig`).
        old_conf: Whether `conf` is the kernel's of before 2.6.37, as
            BusyBox's is: `-d` and `-D <file>` where the current one takes
            `--alldefconfig` and `--defconfig=<file>`, and `.config` written
            to the working directory, as there is no `KCONFIG_CONFIG`. It
            then runs in a scratch directory with `srctree` naming the tree,
            as `make O=` runs it, and the file is moved out.
        **kwargs: Common attributes for the `run_binary`.
    """
    args = [
        "--conf",
        "$(execpath {})".format(conf),
        "--kconfig",
        "$(execpath {})".format(kconfig),
        "--out",
        "$(execpath {}.config)".format(name),
        "--body",
        "$(execpath {}_body.txt)".format(name),
    ]
    if defconfig:
        args += ["--defconfig", "$(execpath {})".format(defconfig)]
    if old_conf:
        args.append("--old-conf")
    run_binary(
        name = name,
        srcs = [conf, kconfig, srcs] + ([defconfig] if defconfig else []),
        outs = [
            name + ".config",
            name + "_body.txt",
        ],
        args = args,
        env = env,
        tool = "//:conf_config",
        **kwargs
    )

def kconfig_conf_test(*, name, repo, conf, kconfig, srcs, env, defconfig = None, old_conf = False, **kwargs):
    """A test that a generated repository's `rendered.config` is the tree's own.

    Args:
        name: The name of the test.
        repo: The repository `kconfig.repo` generated from the tree with
            `defconfig` as its defaults file and `env` as its variables, or
            the `kconfig.overrides` layered on the tree's repository with
            `defconfig` as its config, as `@name`.
        conf: As `conf_config`.
        kconfig: As `conf_config`.
        srcs: As `conf_config`.
        env: As `conf_config`.
        defconfig: As `conf_config`.
        old_conf: As `conf_config`.
        **kwargs: Common attributes for the test.
    """
    conf_config(
        name = name + "_conf",
        conf = conf,
        defconfig = defconfig,
        env = env,
        kconfig = kconfig,
        old_conf = old_conf,
        srcs = srcs,
    )
    diff_test(
        name = name,
        failure_message = "{}//:rendered.config is not the `.config` the tree's own `conf` writes".format(repo),
        file1 = ":" + name + "_conf_body.txt",
        file2 = repo + "//:rendered.config",
        **kwargs
    )
