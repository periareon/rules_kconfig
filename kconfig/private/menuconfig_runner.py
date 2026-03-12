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
        "--kconfig", type=Path, required=True, help="Root Kconfig file path"
    )
    parser.add_argument(
        "--defaults", type=Path, required=True, help="Workspace-relative .config path"
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

    os.chdir(workspace)
    os.environ["KCONFIG_CONFIG"] = os.path.abspath(args.defaults)

    sys.argv = [sys.argv[0], os.path.abspath(args.kconfig)]

    menuconfig.menuconfig(kconfiglib.standard_kconfig())


if __name__ == "__main__":
    main()
