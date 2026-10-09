#!/usr/bin/env bash
#
# prepare-rvvm.sh - prepare a patched upstream RVVM source tree for rvvm-ios
#
# Clones upstream LekKit/RVVM at the pinned commit (reusing an existing
# checkout when possible), then applies the patch series from patches/.
#
# The result is a self-contained RVVM tree containing all iOS-specific and
# device work (virtio-fs, virtio-input, virtio-gpu, net fixes, ...) that the
# Theos build compiles against.
#
# Usage:
#   scripts/prepare-rvvm.sh [dest]        # default: external/rvvm
#
# Environment overrides:
#   RVVM_REPO    git URL to clone from (default: upstream GitHub)
#   RVVM_COMMIT  commit to check out (default: pinned below)
#   RVVM_REF     branch/tag hint for fetching (default: staging)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEST="${1:-${REPO_ROOT}/external/rvvm}"
RVVM_REPO="${RVVM_REPO:-https://github.com/LekKit/RVVM.git}"
# Pinned upstream base for the patch series (branch: staging)
RVVM_COMMIT="${RVVM_COMMIT:-2799ffac4d5b306c3f86b4291b0603d3906673fa}"
RVVM_REF="${RVVM_REF:-staging}"

PATCH_DIR="${REPO_ROOT}/patches"

log() { echo "prepare-rvvm: $*"; }
die() { echo "prepare-rvvm: ERROR: $*" >&2; exit 1; }

[ -d "${PATCH_DIR}" ] || die "patch directory not found: ${PATCH_DIR}"

# -----------------------------------------------------------------------------

# 1. Obtain the source tree
if [ -d "${DEST}/.git" ]; then
    log "reusing existing checkout at ${DEST}"
    git -C "${DEST}" fetch --all --tags -q 2>/dev/null || log "fetch failed (offline?), continuing with local objects"
    git -C "${DEST}" checkout -q "${RVVM_COMMIT}" 2>/dev/null \
        || git -C "${DEST}" checkout -q -B rvvm-ios-base "${RVVM_COMMIT}" \
        || die "commit ${RVVM_COMMIT} not present in ${DEST} and fetch failed"
    git -C "${DEST}" reset -q --hard
    git -C "${DEST}" clean -qfdx -e build
elif [ -d "${DEST}" ] && [ -n "$(ls -A "${DEST}" 2>/dev/null)" ]; then
    die "${DEST} exists and is not empty, refusing to touch it"
else
    log "cloning ${RVVM_REPO} into ${DEST}"
    mkdir -p "$(dirname "${DEST}")"
    if git clone -q --branch "${RVVM_REF}" "${RVVM_REPO}" "${DEST}"; then
        :
    else
        # Full clone fallback (older git without --branch support for the ref)
        git clone -q "${RVVM_REPO}" "${DEST}"
    fi
    git -C "${DEST}" checkout -q "${RVVM_COMMIT}" || die "commit ${RVVM_COMMIT} not found after clone"
fi

# 2. Apply patches (skip ones already applied - idempotent)
cd "${DEST}"
APPLIED=0
SKIPPED=0
for patch in "${PATCH_DIR}"/*.patch; do
    [ -e "${patch}" ] || die "no patches found in ${PATCH_DIR}"
    name="$(basename "${patch}")"
    if git apply --check "${patch}" 2>/dev/null; then
        git apply "${patch}"
        log "applied ${name}"
        APPLIED=$((APPLIED + 1))
    elif git apply --reverse --check "${patch}" 2>/dev/null; then
        log "already applied: ${name}"
        SKIPPED=$((SKIPPED + 1))
    else
        die "patch ${name} does not apply (base mismatch?)"
    fi
done
log "done: ${APPLIED} applied, ${SKIPPED} already present"

exit 0
