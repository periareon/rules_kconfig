#!/bin/sh
# Runs a tree's own `scripts/kconfig/conf` the way `make <defconfig>` or
# `make alldefconfig` does and writes the `.config`, and the same file without
# the heading `conf` writes, for comparing with a generated repository's
# `rendered.config`. `conf_config` of defs.bzl runs this with `run_binary`.
#
#   conf_config.sh --conf PATH --kconfig PATH --out PATH --body PATH
#                  [--defconfig PATH] [--old-conf]
#
# The tree's variables come through the environment. `--old-conf` is for the
# `conf` of kernels before 2.6.37, as BusyBox's: `-d` and `-D FILE` where the
# current one takes `--alldefconfig` and `--defconfig=FILE`, and `.config`
# written to the working directory, as there is no `KCONFIG_CONFIG`; it runs
# in a scratch directory with `srctree` naming the tree, as `make O=` runs it.
set -e

old_conf=
defconfig=
while [ $# -gt 0 ]; do
    case "$1" in
        --conf) conf="$PWD/$2"; shift 2 ;;
        --kconfig) kconfig="$2"; shift 2 ;;
        --defconfig) defconfig="$PWD/$2"; shift 2 ;;
        --out) out="$PWD/$2"; shift 2 ;;
        --body) body="$PWD/$2"; shift 2 ;;
        --old-conf) old_conf=1; shift ;;
        *) echo "conf_config.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done

tree="$PWD/$(dirname "$kconfig")"
root="$(basename "$kconfig")"

if [ -n "$old_conf" ]; then
    scratch="$(mktemp -d)"
    cd "$scratch"
    export srctree="$tree"
    if [ -n "$defconfig" ]; then
        "$conf" -D "$defconfig" "$root" > /dev/null
    else
        "$conf" -d "$root" > /dev/null
    fi
    mv .config "$out"
    # Besides `.config`, the old `conf` leaves `.tmpconfig.h` and
    # `.kconfig.d` (the dependencies, `file_write_dep`) behind.
    rm -f .tmpconfig.h .kconfig.d
    cd / && rmdir "$scratch"
else
    cd "$tree"
    export srctree=. KCONFIG_CONFIG="$out"
    if [ -n "$defconfig" ]; then
        "$conf" --defconfig="$defconfig" "$root" > /dev/null
    else
        "$conf" --alldefconfig "$root" > /dev/null
    fi
fi

# The heading is the four lines naming the tree and its version
# (`# Linux/x86 6.12.0 Kernel Configuration`; `# Busybox version: 1.37.0`,
# with `KCONFIG_NOTIMESTAMP` set), which `rendered.config` has no counterpart
# to; everything else is compared as `conf` writes it.
tail -n +5 "$out" > "$body"
