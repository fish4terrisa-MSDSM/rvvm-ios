#!/bin/bash
# Build a Debian sid riscv64 rootfs + raw disk image for RVVM testing.
#
# The rootfs contains everything needed to exercise both virtio-gpu backends:
#   - mesa with the venus Vulkan driver (libvulkan_virtio) + zink + softpipe
#   - glmark2 (OpenGL/ES benchmark; via zink->venus or softpipe->2D)
#   - vkmark (Vulkan benchmark; directly on venus)
#   - vulkan-tools, e2fsprogs, openssh, systemd, networking
#
# Usage: scripts/build-guest-image.sh <workdir> <image.raw> [size]
set -euo pipefail

WORKDIR="${1:?usage: build-guest-image.sh <workdir> <image.raw> [size]}"
IMAGE="${2:?usage: build-guest-image.sh <workdir> <image.raw> [size]}"
SIZE="${3:-8G}"
ROOTFS="$WORKDIR/rootfs"

sudo apt-get update -qq
sudo apt-get install -y -qq debootstrap qemu-user-static binfmt-support \
    e2fsprogs rsync kmod debian-archive-keyring

rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"

echo "== debootstrap sid riscv64 (foreign) =="
sudo debootstrap --arch=riscv64 --variant=minbase --foreign \
    --include=systemd-sysv,dbus \
    sid "$ROOTFS" http://deb.debian.org/debian

sudo cp /usr/bin/qemu-riscv64-static "$ROOTFS/usr/bin/"
sudo chroot "$ROOTFS" /debootstrap/debootstrap --second-stage

echo "== install packages (native under qemu-user) =="
sudo chroot "$ROOTFS" apt-get update -qq
sudo chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    mesa-vulkan-drivers mesa-gl libgl1-mesa-dri libegl-mesa0 libgles2-mesa libglx-mesa0 \
    glmark2 vkmark vulkan-tools \
    e2fsprogs openssh-server sudo systemd-sysv iproute2 iputils-ping \
    ca-certificates wget curl less nano vim-tiny python3 \
    locales tzdata

echo "== verify venus ICD present =="
sudo chroot "$ROOTFS" ls -l /usr/share/vulkan/icd.d/ /usr/lib/riscv64-linux-gnu/libvulkan_virtio.so

echo "== configure rootfs =="
sudo chroot "$ROOTFS" bash -c '
    set -e
    echo "rvvm-guest" > /etc/hostname
    echo "root:rvvm" | chpasswd
    cat > /etc/fstab <<EOF
/dev/nvme0n1  /  ext4  errors=remount-ro  0  1
proc          /proc proc defaults         0  0
tmpfs         /tmp  tmpfs defaults        0  0
EOF
    mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d
    cat > /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I \$TERM
EOF
    systemctl enable serial-getty@ttyS0.service
    mkdir -p /etc/systemd/network
    cat > /etc/systemd/network/20-wired.network <<EOF
[Match]
Name=en* eth*

[Network]
DHCP=yes
EOF
    systemctl enable systemd-networkd.service
    systemctl enable ssh.service || true
    ln -sf /usr/lib/systemd/systemd /sbin/init
'

# Guest benchmark helper (runs inside the VM)
sudo tee "$ROOTFS/usr/local/bin/gpu-bench" >/dev/null <<'EOF'
#!/bin/sh
# GPU backend benchmark harness for rvvm-ios guests.
#   gpu-bench venus   - vkmark + glmark2-es2 via zink -> venus Vulkan
#   gpu-bench 2d      - glmark2-es2 via softpipe -> virtio-gpu 2D scanout
set -e
MODE="${1:-venus}"
cd /tmp
echo "== rvvm gpu-bench mode=$MODE =="
vulkaninfo --summary 2>/dev/null | sed -n '1,40p' || true
case "$MODE" in
venus)
    export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/virtio_icd.json
    export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/virtio_icd.json
    export GALLIUM_DRIVER=zink
    echo "--- vkmark (venus) ---"
    vkmark --size 800x600 2>&1 | tee vkmark-venus.txt
    echo "--- glmark2-es2 (zink -> venus) ---"
    glmark2-es2 --size 800x600 --run-forever 0 2>&1 | tee glmark2-venus.txt || \
        glmark2-es2 --size 800x600 2>&1 | tee glmark2-venus.txt
    ;;
2d)
    export GALLIUM_DRIVER=softpipe
    export LIBGL_ALWAYS_SOFTWARE=1
    echo "--- glmark2-es2 (softpipe -> virtio-gpu 2D) ---"
    glmark2-es2 --size 800x600 2>&1 | tee glmark2-2d.txt
    ;;
*)
    echo "usage: gpu-bench venus|2d" >&2; exit 2 ;;
esac
echo "== done =="
EOF
sudo chmod +x "$ROOTFS/usr/local/bin/gpu-bench"

# Drop a note in the image
sudo tee "$ROOTFS/etc/motd" >/dev/null <<'EOF'
rvvm-ios guest test image (Debian sid riscv64)
  root password: rvvm
  gpu-bench venus   -> vkmark + glmark2 via Venus (virtio-gpu Vulkan)
  gpu-bench 2d      -> glmark2 via softpipe (virtio-gpu 2D)
EOF

sudo rm -f "$ROOTFS/usr/bin/qemu-riscv64-static"

echo "== create sparse disk image $IMAGE ($SIZE) =="
rm -f "$IMAGE"
truncate -s "$SIZE" "$IMAGE"
mkfs.ext4 -F -L rvvm-root -O ^has_journal "$IMAGE"
MNT="$WORKDIR/mnt"
mkdir -p "$MNT"
sudo mount -o loop "$IMAGE" "$MNT"
sudo rsync -aHAX --numeric-ids "$ROOTFS/" "$MNT/"
sudo umount "$MNT"
# Re-sparsify: punch freed holes so the artifact stays small.
e2fsck -fy "$IMAGE" || true
echo "image ready: $IMAGE ($(du -h --apparent-size "$IMAGE" | cut -f1) apparent, $(du -h "$IMAGE" | cut -f1) on disk)"
