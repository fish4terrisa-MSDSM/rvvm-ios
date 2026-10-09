# rvvm-ios

An iOS app wrapper around [RVVM](https://github.com/LekKit/RVVM) (RISC-V virtual machine), built with Theos.

RVVM is not a submodule. `scripts/prepare-rvvm.sh` clones upstream RVVM at a pinned commit into `RVVM/` (git-ignored) and applies the iOS patch series in `patches/` on top. The Makefile runs it at parse time, so every build starts from the same reproducible tree.

## Repository layout

- `patches/`: iOS-specific RVVM patches (applied in order onto the pinned upstream commit)
- `scripts/prepare-rvvm.sh`: fetches upstream RVVM and applies `patches/`
- `RVVM/`: generated upstream checkout (not tracked)
- `Resources/`: app resources (Linux firmware/DTB, xterm.js assets)
- `RV64Runner.mm`, `RV64RootViewController.m`, `RV64AppDelegate.m`: iOS UI and VM integration
- `entitlements.plist`: increased memory limit, JIT, and debugger entitlements
- `.github/workflows/build-ipa.yml`: builds the `.ipa` on merged pull requests and on manual dispatch

## Build (Theos)

### Prerequisites

- Theos installed and the `THEOS` environment variable set
- iOS SDK available to Theos
- `curl` (fetches xterm.js assets on first build)
- `ldid` (fake-signs with the entitlements in `entitlements.plist`)

### Build the app

```bash
make
```

The `.app` is written to `.theos/obj/debug/rvvm.app`.

### Build an IPA

```bash
make ipa
```

The IPA is written to `packages/`. The bundled Linux images are not included. Use the in-app ISO and disk settings instead.

### Continuous builds

`.github/workflows/build-ipa.yml` builds the IPA when a pull request is merged into the repository and on manual `workflow_dispatch`. Download it from the run's artifacts (`rvvm-ipa`).

## Using the app

- **Boot**: pick an ISO (import from Files, or disable it), a disk image, and port forwards.
- **Hardware**: cores, RAM (up to 8 GB where the device allows), graphics (simple framebuffer or virtio-gpu 2D), touch input (trackpad or direct touch), background behaviour (off, silent audio, or a background task), firmware (bundled OpenSBI or an imported one), extra disks, and the virtio-fs shared folder.
- **Documents**: create sparse raw disk images, import disks (imported images are stored sparse), export files, and browse `logs/console.log`. All of this is visible in the Files app under "On My iPhone > rvvm".
- **JIT**: enable it with StikDebug. The app never passes `nojit`, so RVVM falls back to the interpreter when JIT is unavailable.
