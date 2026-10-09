#!/bin/sh
# prepare-rvvm.sh - fetch upstream RVVM at a pinned commit and apply the iOS patch series.
#
# Usage: scripts/prepare-rvvm.sh [RVVM_DIR]
#
# The checkout lives in RVVM/ (git-ignored). Every run resets it to the pinned
# upstream commit and applies patches/*.patch in order, so the result is always
# reproducible from (RVVM_COMMIT, patches/). A stamp file records what was
# applied, and an up-to-date checkout is left untouched.
#
# Environment overrides:
#   RVVM_REPO    upstream URL          (default: https://github.com/LekKit/RVVM.git)
#   RVVM_COMMIT  pinned commit         (default: see below)
#   RVVM_FORCE   1 = re-apply even if the stamp matches

set -eu

RVVM_REPO="${RVVM_REPO:-https://github.com/LekKit/RVVM.git}"
# Upstream staging at the point the iOS port was made (LekKit/RVVM 2799ffac).
RVVM_COMMIT="${RVVM_COMMIT:-2799ffac4d5b306c3f86b4291b0603d3906673fa}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RVVM_DIR="${1:-$ROOT/RVVM}"
PATCH_DIR="$ROOT/patches"
STAMP_NAME=".rvvm-ios-stamp"

if [ ! -d "$PATCH_DIR" ]; then
    echo "prepare-rvvm: missing $PATCH_DIR" >&2
    exit 1
fi

# Fingerprint: pinned commit plus the content of every patch, in order.
fingerprint() {
    {
        echo "$RVVM_COMMIT"
        for p in "$PATCH_DIR"/*.patch; do
            [ -f "$p" ] || continue
            cat "$p"
        done
    } | (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1
}

WANT="$(fingerprint)"

if [ -f "$RVVM_DIR/$STAMP_NAME" ] && [ "${RVVM_FORCE:-0}" != "1" ] \
   && [ "$(cat "$RVVM_DIR/$STAMP_NAME")" = "$WANT" ]; then
    echo "prepare-rvvm: $RVVM_DIR already at $RVVM_COMMIT with patches applied"
    exit 0
fi

mkdir -p "$RVVM_DIR"
if [ ! -d "$RVVM_DIR/.git" ]; then
    # Clone into a directory that may already exist (empty placeholder).
    git -C "$RVVM_DIR" init -q
    git -C "$RVVM_DIR" remote add origin "$RVVM_REPO"
fi

echo "prepare-rvvm: fetching $RVVM_COMMIT from $RVVM_REPO"
git -C "$RVVM_DIR" fetch -q --depth 1 origin "$RVVM_COMMIT" || git -C "$RVVM_DIR" fetch -q origin
git -C "$RVVM_DIR" checkout -q -f --detach "$RVVM_COMMIT"
git -C "$RVVM_DIR" reset -q --hard "$RVVM_COMMIT"
git -C "$RVVM_DIR" clean -qfdx

git -C "$RVVM_DIR" config user.name "rvvm-ios"
git -C "$RVVM_DIR" config user.email "rvvm-ios@localhost"

for p in "$PATCH_DIR"/*.patch; do
    [ -f "$p" ] || continue
    echo "prepare-rvvm: applying $(basename "$p")"
    if ! git -C "$RVVM_DIR" am -q "$p"; then
        git -C "$RVVM_DIR" am --abort >/dev/null 2>&1 || true
        echo "prepare-rvvm: failed to apply $(basename "$p")" >&2
        exit 1
    fi
done

printf '%s\n' "$WANT" > "$RVVM_DIR/$STAMP_NAME"
echo "prepare-rvvm: done ($(git -C "$RVVM_DIR" rev-parse --short HEAD))"
