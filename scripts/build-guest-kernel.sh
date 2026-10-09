#!/bin/bash
# Build a riscv64 Linux kernel for the RVVM guest.
#
# Usage: scripts/build-guest-kernel.sh <workdir> [kernel_tag]
#
# Produces: <workdir>/Image   (riscv64 boot image, for RVVM -kernel)
set -euo pipefail

WORKDIR="${1:?usage: build-guest-kernel.sh <workdir> [kernel_tag]}"
KERNEL_TAG="${2:-v6.12}"
JOBS="$(nproc)"

mkdir -p "$WORKDIR"
SRC="$WORKDIR/linux"

if [ ! -d "$SRC/.git" ]; then
    git clone --quiet --depth 1 --branch "$KERNEL_TAG" https://github.com/torvalds/linux.git "$SRC"
fi

cd "$SRC"

make ARCH=riscv64 CROSS_COMPILE=riscv64-linux-gnu- defconfig

# Merge the RVVM fragment (all required drivers built-in).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
./scripts/kconfig/merge_config.sh -m .config "$SCRIPT_DIR/guest-kernel.config"
make ARCH=riscv64 CROSS_COMPILE=riscv64-linux-gnu- olddefconfig

echo "=== effective virtio/drm/nvme config ==="
grep -E 'CONFIG_(VIRTIO|DRM_VIRTIO_GPU|BLK_DEV_NVME|FUSE_FS|SERIAL_8250|R8169)' .config | head -30

make ARCH=riscv64 CROSS_COMPILE=riscv64-linux-gnu- -j"$JOBS" Image

cp -a arch/riscv64/boot/Image "$WORKDIR/Image"
grep -E 'CONFIG_(VIRTIO|DRM|BLK_DEV_NVME|FUSE|VIRTIO_FS|SERIAL_8250|R8169|INPUT_EVDEV)' "$SRC/.config" > "$WORKDIR/kernel-config-report.txt"

echo "kernel image: $WORKDIR/Image ($(stat -c%s "$WORKDIR/Image") bytes)"
