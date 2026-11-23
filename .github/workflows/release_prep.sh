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
#                                   kconfig/private/parser/module.bzl names the
#                                   URL and integrity of the module below.
#     kconfig.wasm                  The WebAssembly module the `kconfig`
#                                   extension of this release downloads.
#     kconfig_tool-<os>-<cpu>[.exe] The native builds of the parser, from the
#                                   `binaries` job of release.yaml, for the
#                                   Bazels that cannot run the module.
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
MODULE_BZL="${WORKSPACE}/kconfig/private/parser/module.bzl"
cleanup() {
    # Put back the source form of module.bzl; the baked form lives in the archive.
    if [[ -f "${SCRATCH}/module.bzl.orig" ]]; then
        cp "${SCRATCH}/module.bzl.orig" "${MODULE_BZL}"
    fi
    rm -rf "${SCRATCH}"
}
trap cleanup EXIT

# Build the WebAssembly backend: the kernel's Kconfig parser and this
# repository's generators in Rust, built for wasm32-wasip1 from inputs pinned
# by their hashes (the kernel sources, the Rust toolchain, the wasi-sdk). It
# is attached to the release and attested with the archive, and its integrity
# is baked into the archive's module.bzl so that the `kconfig` extension of
# this release downloads exactly this module. `kconfig_wasm_release` builds
# it in opt for wasm32-wasip1 whatever the flags, and publishes it here as
# `kconfig.wasm` (see tools/release).
DEST="$(pwd)"
(cd "${WORKSPACE}" && bazel run //kconfig/private/parser:kconfig_wasm_release -- "${DEST}")
integrity() {
    echo "sha256-$(shasum --algorithm 256 "$1" | awk '{ print $1 }' | xxd -r -p | base64)"
}
MODULE_INTEGRITY="$(integrity kconfig.wasm)"
if ! grep -q '^MODULE_INTEGRITY = ""$' "${MODULE_BZL}"; then
    echo "ERROR: ${MODULE_BZL} has no empty MODULE_INTEGRITY to fill in"
    exit 1
fi
cp "${MODULE_BZL}" "${SCRATCH}/module.bzl.orig"
sed -i.bak "s|^MODULE_INTEGRITY = \"\"$|MODULE_INTEGRITY = \"${MODULE_INTEGRITY}\"|" "${MODULE_BZL}" && rm -f "${MODULE_BZL}.bak"
grep -q "^MODULE_INTEGRITY = \"${MODULE_INTEGRITY}\"$" "${MODULE_BZL}"

# The native builds, from the `binaries` job of release.yaml. The reusable
# workflow runs `actions/download-artifact` with no `path`, which unpacks
# every artifact of the run into `${GITHUB_WORKSPACE}/<artifact name>/`;
# its own comment says `artifacts/`, where older versions put them, so both
# are accepted. Each artifact directory shares its name with the release
# asset it holds, so it is moved out of the workspace before the asset is
# copied into cwd; left in place it would also match the `kconfig_tool-*`
# glob of `release_files`. Each build is attached and its integrity baked
# in; a platform with no build is left empty, and the extension offers no
# native build there.
mkdir -p "${SCRATCH}/artifacts"
TOOL_INTEGRITIES=""
TOOLS_FOUND=0
for key in linux-aarch64 linux-x86_64 macos-aarch64 windows-aarch64 windows-x86_64; do
    for dir in "${WORKSPACE}/artifacts/kconfig_tool-${key}" "${WORKSPACE}/kconfig_tool-${key}"; do
        if [[ -d "${dir}" ]]; then
            mv "${dir}" "${SCRATCH}/artifacts/kconfig_tool-${key}"
            break
        fi
    done
    rm -f "kconfig_tool-${key}" "kconfig_tool-${key}.exe"
    built="$(ls "${SCRATCH}/artifacts/kconfig_tool-${key}/kconfig_tool-${key}"* 2>/dev/null | head -n 1 || true)"
    if [[ -z "${built}" ]]; then
        echo "WARNING: no native build for ${key}; the release will carry none"
        continue
    fi
    TOOLS_FOUND=$((TOOLS_FOUND + 1))
    cp "${built}" "$(basename "${built}")"
    chmod 0755 "$(basename "${built}")"
    tool_integrity="$(integrity "$(basename "${built}")")"
    sed -i.bak "s|^    \"${key}\": \"\",$|    \"${key}\": \"${tool_integrity}\",|" "${MODULE_BZL}" && rm -f "${MODULE_BZL}.bak"
    grep -q "^    \"${key}\": \"${tool_integrity}\",$" "${MODULE_BZL}"
    TOOL_INTEGRITIES="${TOOL_INTEGRITIES}- \`${key}\`: \`${tool_integrity}\`
"
done
# No build at all means the artifact layout changed under us, not that
# every platform was skipped; refuse to publish a release without them.
if [[ "${TOOLS_FOUND}" -eq 0 ]]; then
    echo "ERROR: no native builds found under ${WORKSPACE}; did the binaries job upload them?"
    exit 1
fi

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
    --exclude="./kconfig_tool-*" \
    --exclude="./artifacts" \
    -C "${WORKSPACE}" .
mv "${SCRATCH}/${ARCHIVE}" "${ARCHIVE}"

# Render release notes by substituting {version} and {module_integrity}
# into the template. release_notes.template lives in `.github/`.
printf '%s' "${TOOL_INTEGRITIES:-- none}" > "${SCRATCH}/tool_integrities.txt"
sed -e "s#{version}#${TAG}#g" -e "s#{module_integrity}#${MODULE_INTEGRITY}#g" \
    -e "/{tool_integrities}/{
r ${SCRATCH}/tool_integrities.txt
d
}" \
    "${WORKSPACE}/.github/release_notes.template" > "${SCRATCH}/release_notes.txt"

# Emit the rendered notes on the original stdout (fd 3) — that's the
# only thing the reusable workflow captures into release_notes.txt.
cat "${SCRATCH}/release_notes.txt" >&3
