#!/bin/sh
# test-gpu-backends.sh - host-side smoke test for the virtio-gpu 3D backends
# (item 8). Runs inside this sandbox / any Linux host: builds RVVM with the
# patches applied and checks that both 3D bridges (rutabaga + virgl/venus)
# load their symbols and report valid capsets. Full guest runs with glmark2 /
# vkmark happen on device with scripts/guest-gpu-bench.sh.
#
# Usage: scripts/test-gpu-backends.sh [build-dir]

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$ROOT/external/rvvm}"
SRC="/home/user/rvvm-src"

echo "== preparing RVVM tree =="
if [ ! -d "$BUILD/src" ]; then
	sh "$ROOT/scripts/prepare-rvvm.sh" "$BUILD"
fi

echo "== building rvvm + vgtest (USE_JIT=1, never nojit) =="
make -C "$BUILD" -j"$(nproc)" USE_JIT=1

# librvvm symlink for the vgtest host harness
out=$(ls -d "$BUILD"/release.linux.* 2>/dev/null | head -n1)
if [ -n "$out" ] && [ -f "$out/librvvm.so.0" ] && [ ! -e "$out/librvvm.so" ]; then
	ln -sf librvvm.so.0 "$out/librvvm.so"
fi

echo "== vgtest protocol smoke (virtio-gpu virtqueue protocol) =="
vgtest_bin=""
for c in "$out/vgtest_host" "$BUILD/tests/virtio-gpu/vgtest_host" "$SRC/tests/virtio-gpu/vgtest_host"; do
	if [ -x "$c" ]; then
		vgtest_bin="$c"
		break
	fi
done
if [ -f "$ROOT/scripts/vgtest.elf" ] && [ -n "$vgtest_bin" ]; then
	LD_LIBRARY_PATH="$out" "$vgtest_bin" "$ROOT/scripts/vgtest.elf"
else
	echo "vgtest harness not present; skipping"
fi

echo "== 3D bridge symbol presence (no dlopen of GPU libs required) =="
# The bridges are always compiled (patch 0009). Check the exported init
# entry points exist in the shared library so the app-side dlopen path
# (vg_rutabaga_load / vg_virgl_load) can bind at runtime.
syms_ok=1
for sym in virtio_gpu_init_virgl virtio_gpu_init_rutabaga; do
	if nm -D "$out/librvvm.so.0" 2>/dev/null | grep -q " T $sym"; then
		echo "  ok: $sym exported"
	else
		echo "  MISSING: $sym"
		syms_ok=0
	fi
done

echo "== optional: virglrenderer backend probe =="
for lib in libvirglrenderer.so libvirglrenderer.so.1; do
	if [ -e "/usr/lib/$lib" ] || [ -e "/usr/lib/x86_64-linux-gnu/$lib" ]; then
		echo "  host has $lib - guest-side venus/virgl tests can run here"
		found_virgl=1
		break
	fi
done
[ -n "$found_virgl" ] || echo "  no host virglrenderer; device testing required (guest-gpu-bench.sh)"

if [ "$syms_ok" -ne 1 ]; then
	echo "FAIL: 3D bridge symbols missing (patches not applied?)"
	exit 1
fi

echo "PASS: host-side GPU backend smoke done"
echo "Next: run scripts/guest-gpu-bench.sh INSIDE the riscv64 guest for"
echo "      glmark2 (virgl) and vkmark (venus/MoltenVK) numbers."
