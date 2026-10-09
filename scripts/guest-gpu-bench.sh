#!/bin/sh
# guest-gpu-bench.sh - run INSIDE the riscv64 Linux guest (Alpine/Arch riscv64)
# to benchmark the virtio-gpu 3D backends (item 8):
#   - "virgl"  -> GLES via virglrenderer  -> glmark2-es2-wayland / glmark2
#   - "venus"  -> Vulkan via virglrenderer+MoltenVK (Venus protocol) -> vkmark
#   - "rutabaga" -> gfxstream forwarded GLES/Vulkan -> both
#
# Results are written to the virtio-fs share (mount -t virtiofs share /mnt)
# so the iOS side can read them from Documents/logs.
#
# Usage: sh guest-gpu-bench.sh [share-mount]

set -e

SHARE="${1:-/mnt}"
OUT="$SHARE/logs"
mkdir -p "$OUT" 2>/dev/null || OUT=/tmp
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$OUT/gpu-bench-$STAMP.log"

log() {
	echo "$@" | tee -a "$LOG"
}

log "== rvvm-ios guest GPU bench ($STAMP) =="
log "kernel: $(uname -a)"

# 1. Device presence
log "-- virtio-gpu device --"
if [ -e /sys/bus/virtio/devices ]; then
	for d in /sys/bus/virtio/devices/virtio*; do
		[ -e "$d" ] || continue
		dev="$(cat "$d/device" 2>/dev/null || true)"
		log "  $(basename "$d") device=$dev"
	done
fi
ls /dev/dri 2>/dev/null | while read -r n; do log "  /dev/dri/$n"; done || log "  no /dev/dri (2D only?)"

# 2. Detect what is usable
HAVE_GL=0
HAVE_VK=0
if ls /dev/dri/card* >/dev/null 2>&1 || ls /dev/dri/renderD* >/dev/null 2>&1; then
	command -v glxinfo >/dev/null 2>&1 && HAVE_GL=1
	command -v vkcube >/dev/null 2>&1 || command -v vkcube-wayland >/dev/null 2>&1 && HAVE_VK=1
fi

# 3. GLES/glmark2 (virgl path)
if command -v glmark2-es2-wayland >/dev/null 2>&1; then
	log "-- glmark2-es2-wayland --"
	glmark2-es2-wayland --annotate 2>&1 | tee -a "$LOG" || true
elif command -v glmark2-es2 >/dev/null 2>&1; then
	log "-- glmark2-es2 --"
	glmark2-es2 2>&1 | tee -a "$LOG" || true
elif command -v glmark2 >/dev/null 2>&1; then
	log "-- glmark2 --"
	glmark2 2>&1 | tee -a "$LOG" || true
else
	log "-- glmark2 not installed (apk add glmark2 / pacman -S glmark2) --"
fi

# 4. Vulkan/vkmark (venus path; MoltenVK-style ICD via Venus)
if command -v vkmark >/dev/null 2>&1; then
	log "-- vkmark --"
	if [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; then
		vkmark 2>&1 | tee -a "$LOG" || true
	else
		vkmark -w 800x600 2>&1 | tee -a "$LOG" || true
	fi
elif command -v vkcube >/dev/null 2>&1; then
	log "-- vkcube (smoke) --"
	timeout 5 vkcube 2>&1 | tee -a "$LOG" || true
else
	log "-- vkmark not installed (apk add vkmark / pacman -S vulkan-tools) --"
fi

log "== done; log at $LOG =="
echo "$LOG"
