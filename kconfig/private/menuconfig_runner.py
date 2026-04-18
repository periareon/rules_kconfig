"""Entry point for the menuconfig TUI, invoked via `bazel run`."""

import argparse
import os
import platform
import sys
from pathlib import Path
from typing import Optional, Sequence

import kconfiglib  # type: ignore[import-untyped]
import menuconfig  # type: ignore[import-untyped]
from python.runfiles import Runfiles


def _rlocation(runfiles: Runfiles, rlocationpath: str) -> Path:
    """Look up a runfile and ensure the file exists

    Args:
        runfiles: The runfiles object
        rlocationpath: The runfile key

    Returns:
        The requested runifle.
    """
    # TODO: https://github.com/periareon/rules_venv/issues/37
    source_repo = None
    if platform.system() == "Windows":
        source_repo = ""
    runfile = runfiles.Rlocation(rlocationpath, source_repo)
    if not runfile:
        raise FileNotFoundError(f"Failed to find runfile: {rlocationpath}")
    path = Path(runfile)
    if not path.exists():
        raise FileNotFoundError(f"Runfile does not exist: ({rlocationpath}) {path}")
    return path


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    """Parse command line arguments"""

    parser = argparse.ArgumentParser(description="Interactive Kconfig editor")
    parser.add_argument(
        "--kconfig",
        type=str,
        required=True,
        help="Rlocation path to the root Kconfig file",
    )
    parser.add_argument(
        "--config",
        type=str,
        required=True,
        help="Workspace-relative path to the .config file",
    )

    return parser.parse_args(argv)


def main() -> None:
    """The main entrypoint."""

    workspace = os.environ.get("BUILD_WORKSPACE_DIRECTORY")
    if not workspace:
        raise EnvironmentError("menuconfig must be run via 'bazel run'")

    runfiles = Runfiles.Create()
    if not runfiles:
        raise EnvironmentError("Failed to locate runfiles.")

    args_file = _rlocation(runfiles, os.environ["RULES_KCONFIG_MENUCONFIG_ARGS_FILE"])

    argv = args_file.read_text(encoding="utf-8").splitlines()
    args = parse_args(argv)

    config_path = os.path.join(workspace, args.config)
    real_config = os.path.realpath(config_path)
    real_workspace = os.path.realpath(workspace)
    if (
        not real_config.startswith(real_workspace + os.sep)
        and real_config != real_workspace
    ):
        raise EnvironmentError(
            f"The config file must be within the root module's workspace directory.\n"
            f"  config resolves to: {real_config}\n"
            f"  workspace root:     {real_workspace}"
        )

    kconfig_root = _rlocation(runfiles, args.kconfig)

    os.environ["KCONFIG_CONFIG"] = config_path
    os.environ["srctree"] = str(kconfig_root.parent)
    sys.argv = [sys.argv[0], str(kconfig_root)] + sys.argv[1:]

    menuconfig.menuconfig(kconfiglib.standard_kconfig())


if __name__ == "__main__":
    main()
