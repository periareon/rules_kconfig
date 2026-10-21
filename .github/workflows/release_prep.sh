#!/usr/bin/env bash
# Build the rules_kconfig release assets and emit release notes.
# Invoked by bazel-contrib/.github/.github/workflows/release_ruleset.yaml
# at the hardcoded path `.github/workflows/release_prep.sh`.
#
# Args:
#   $1: tag name (e.g. 0.5.0). Must match VERSION in version.bzl and the
#       module version in MODULE.bazel.
#
# Side effects:
#   Writes the following to the current directory. These paths must match
#   the `release_files` globs in release.yaml.
#     rules_kconfig-${TAG}.tar.gz   The Bazel module source archive, whose
#                                   kconfig/private/wasm/module.bzl names the
#                                   URL and integrity of the module below.
#     kconfig.wasm                  The WebAssembly backend the `kconfig`
#                                   extension of this release downloads.
#
# Output:
#   Release notes to stdout. The release_ruleset workflow redirects
#   stdout into release_notes.txt for the GitHub release body. All
#   other noise (tar, bazel, version checks) goes to stderr.

set -euo pipefail

# Redirect all stdout to stderr; keep fd 3 for the final release-notes write.
exec 3>&1 1>&2

TAG="${1:?tag_name required}"
WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"

# Validate the tag matches version.bzl and MODULE.bazel. release.yaml's
# `validation` job also guards the tag, but checking again here means a
# manual invocation of this script can't drift, and a release commit that
# bumped only one of the two files is rejected before anything is published.
ON_DISK_VERSION="$(grep 'VERSION =' "${WORKSPACE}/version.bzl" | sed 's/VERSION = "//' | sed 's/"//')"
if [[ "${ON_DISK_VERSION}" != "${TAG}" ]]; then
    echo "ERROR: tag ${TAG} does not match version.bzl VERSION=${ON_DISK_VERSION}"
    exit 1
fi
MODULE_VERSION="$(sed -n -E 's/^[[:space:]]*version = "([^"]+)",?$/\1/p' "${WORKSPACE}/MODULE.bazel" | head -n 1)"
if [[ "${MODULE_VERSION}" != "${TAG}" ]]; then
    echo "ERROR: tag ${TAG} does not match MODULE.bazel version=${MODULE_VERSION}"
    exit 1
fi

SCRATCH="$(mktemp -d)"
MODULE_BZL="${WORKSPACE}/kconfig/private/wasm/module.bzl"
cleanup() {
    # Put back the source form of module.bzl; the baked form lives in the archive.
    if [[ -f "${SCRATCH}/module.bzl.orig" ]]; then
        cp "${SCRATCH}/module.bzl.orig" "${MODULE_BZL}"
    fi
    rm -rf "${SCRATCH}"
}
trap cleanup EXIT

# Build the WebAssembly backend: CPython, kconfiglib and this repository's
# generators, built by rules_venv's `py_wasm_module` from inputs pinned by
# their hashes (the CPython devkit, wasi-sdk, Wizer). It is attached to the
# release and attested with the archive, and its integrity is baked into the
# archive's module.bzl so that the `kconfig` extension of this release
# downloads exactly this module.
rm -f kconfig.wasm
(cd "${WORKSPACE}" && bazel build //kconfig/private/wasm:kconfig_wasm)
cp "${WORKSPACE}/$(cd "${WORKSPACE}" && bazel cquery --output=files //kconfig/private/wasm:kconfig_wasm)" kconfig.wasm
chmod 0644 kconfig.wasm
MODULE_INTEGRITY="sha256-$(shasum --algorithm 256 kconfig.wasm | awk '{ print $1 }' | xxd -r -p | base64)"
if ! grep -q '^MODULE_INTEGRITY = ""$' "${MODULE_BZL}"; then
    echo "ERROR: ${MODULE_BZL} has no empty MODULE_INTEGRITY to fill in"
    exit 1
fi
cp "${MODULE_BZL}" "${SCRATCH}/module.bzl.orig"
sed -i.bak "s|^MODULE_INTEGRITY = \"\"$|MODULE_INTEGRITY = \"${MODULE_INTEGRITY}\"|" "${MODULE_BZL}" && rm -f "${MODULE_BZL}.bak"
grep -q "^MODULE_INTEGRITY = \"${MODULE_INTEGRITY}\"$" "${MODULE_BZL}"

# Build the source archive. Exclude .git (history isn't needed by
# consumers), .github (release infrastructure isn't part of the ruleset)
# and anything Bazel may have left in the workspace. The on-disk filename
# matches the URL in `.bcr/source.template.json` — the SLSA attestation
# subject must equal the published asset name.
#
# Stage to a temp path *outside* the workspace before moving into cwd:
# writing the archive into the same directory tar is reading from
# updates that directory's mtime mid-read, which GNU tar surfaces as
# `tar: .: file changed as we read it` and aborts with non-zero.
ARCHIVE="rules_kconfig-${TAG}.tar.gz"
tar -czf "${SCRATCH}/${ARCHIVE}" \
    --exclude="./.git" \
    --exclude="./.github" \
    --exclude="./bazel-*" \
    --exclude="./MODULE.bazel.lock" \
    --exclude="./kconfig.wasm" \
    -C "${WORKSPACE}" .
mv "${SCRATCH}/${ARCHIVE}" "${ARCHIVE}"

# Render release notes by substituting {version} and {module_integrity}
# into the template. release_notes.template lives in `.github/`.
sed -e "s#{version}#${TAG}#g" -e "s#{module_integrity}#${MODULE_INTEGRITY}#g" \
    "${WORKSPACE}/.github/release_notes.template" > "${SCRATCH}/release_notes.txt"

# Emit the rendered notes on the original stdout (fd 3) — that's the
# only thing the reusable workflow captures into release_notes.txt.
cat "${SCRATCH}/release_notes.txt" >&3
