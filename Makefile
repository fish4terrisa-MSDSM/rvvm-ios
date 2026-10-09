TARGET := iphone:clang:latest:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = rvvm

# RVVM sources are prepared by scripts/prepare-rvvm.sh: upstream LekKit/RVVM
# at the pinned commit with the patch series from patches/ applied on build.
RVVM_DIR ?= external/rvvm

# Make sure the RVVM tree (upstream + patches) is present before compiling
.PHONY: prepare-rvvm
prepare-rvvm:
	@scripts/prepare-rvvm.sh $(RVVM_DIR)

before-all:: prepare-rvvm xterm-assets

rvvm_FILES = \
	main.m \
	RV64AppDelegate.m \
	RV64RootViewController.m \
	RV64Runner.mm \
	RV64FileStore.m \
	RV64BackgroundKeeper.m \
	$(wildcard $(RVVM_DIR)/src/core/*.c) \
	$(wildcard $(RVVM_DIR)/src/cpu/*.c) \
	$(wildcard $(RVVM_DIR)/src/rvjit/*.c) \
	$(wildcard $(RVVM_DIR)/src/util/*.c) \
	$(RVVM_DIR)/src/devices/chardev_term.c \
	$(RVVM_DIR)/src/devices/bochs-display.c \
	$(RVVM_DIR)/src/devices/framebuffer.c \
	$(RVVM_DIR)/src/devices/riscv-aclint.c \
	$(RVVM_DIR)/src/devices/riscv-aplic.c \
	$(RVVM_DIR)/src/devices/riscv-imsic.c \
	$(RVVM_DIR)/src/devices/riscv-plic.c \
	$(RVVM_DIR)/src/devices/i2c-oc.c \
	$(RVVM_DIR)/src/devices/i2c-hid.c \
	$(RVVM_DIR)/src/devices/hid-keyboard.c \
	$(RVVM_DIR)/src/devices/hid-mouse.c \
	$(RVVM_DIR)/src/devices/ns16550a.c \
	$(RVVM_DIR)/src/devices/ps2-altera.c \
	$(RVVM_DIR)/src/devices/ps2-keyboard.c \
	$(RVVM_DIR)/src/devices/ps2-mouse.c \
	$(RVVM_DIR)/src/devices/syscon.c \
	$(RVVM_DIR)/src/devices/rtc-goldfish.c \
	$(RVVM_DIR)/src/devices/virtio-fs.c \
	$(RVVM_DIR)/src/devices/virtio-input.c \
	$(RVVM_DIR)/src/devices/virtio-gpu.c \
	$(RVVM_DIR)/src/devices/tap_user.c \
	$(RVVM_DIR)/src/devices/rtl8169.c \
	$(RVVM_DIR)/src/devices/nvme.c \
	$(RVVM_DIR)/src/devices/ata.c \
	$(RVVM_DIR)/src/devices/eth-oc.c

rvvm_FRAMEWORKS = UIKit Foundation WebKit AVFoundation CoreLocation CoreMotion
rvvm_LIBRARIES = pthread

# NOTE: JIT is ALWAYS compiled in and enabled at runtime. RVVM falls back to
# the interpreter by itself when executable pages are unavailable (no JIT
# debugger attached). Never add -UUSE_JIT or pass -nojit.
rvvm_CFLAGS = -fobjc-arc
rvvm_CFLAGS += -O3
rvvm_CFLAGS += -std=gnu11
rvvm_CFLAGS += -DUSE_JIT
rvvm_CFLAGS += -Wno-error=ignored-pragmas
rvvm_CFLAGS += -DNDEBUG -DUSE_RV64 -DUSE_FDT -DUSE_FPU -DUSE_NET
rvvm_CFLAGS += -I$(RVVM_DIR)/include -I$(RVVM_DIR)/src -I$(RVVM_DIR)/src/devices

rvvm_CCFLAGS = \
	-std=gnu++20 \
	-DNDEBUG \
	-O3 \
	-DUSE_RV64 \
	-DUSE_FDT \
	-DUSE_FPU \
	-DUSE_NET \
	-DUSE_JIT \
	-Wno-error=ignored-pragmas \
	-I$(RVVM_DIR)/include \
	-I$(RVVM_DIR)/src \
	-I$(RVVM_DIR)/src/devices

rvvm_OBJCCFLAGS = $(rvvm_CCFLAGS)

rvvm_RESOURCE_DIRS = Resources

# Entitlements: increased memory limit, JIT (dynamic codesigning), file sharing
rvvm_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk

.PHONY: xterm-assets
xterm-assets: Resources/xterm/xterm.js \
              Resources/xterm/xterm.css \
              Resources/xterm/xterm-addon-fit.js

XTERM_VER = 5.3.0
XTERM_FIT_VER = 0.8.0
XTERM_DIR = Resources/xterm

$(XTERM_DIR):
	@mkdir -p "$(XTERM_DIR)"

$(XTERM_DIR)/xterm.js: | $(XTERM_DIR)
	@test -f "$@" || curl -fsSL "https://cdn.jsdelivr.net/npm/xterm@$(XTERM_VER)/lib/xterm.js" -o "$@"

$(XTERM_DIR)/xterm.css: | $(XTERM_DIR)
	@test -f "$@" || curl -fsSL "https://cdn.jsdelivr.net/npm/xterm@$(XTERM_VER)/css/xterm.css" -o "$@"

$(XTERM_DIR)/xterm-addon-fit.js: | $(XTERM_DIR)
	@test -f "$@" || curl -fsSL "https://cdn.jsdelivr.net/npm/xterm-addon-fit@$(XTERM_FIT_VER)/lib/xterm-addon-fit.js" -o "$@"

.PHONY: ipa
ipa: all
	@rm -rf "$(THEOS_OBJ_DIR)/ipa" "$(THEOS_PACKAGE_DIR)/$(APPLICATION_NAME).ipa"
	@mkdir -p "$(THEOS_OBJ_DIR)/ipa/Payload" "$(THEOS_PACKAGE_DIR)"
	@app="$$(find $(THEOS_OBJ_DIR) -name "$(APPLICATION_NAME).app" -maxdepth 4 -type d | head -n1)"; \
		test -n "$$app" || { echo "error: built .app not found under $(THEOS_OBJ_DIR)" >&2; exit 1; }; \
		rm -f "$$app/rv64linux/alpine-standard-3.23.3-riscv64.iso" "$$app/rv64linux/alpine-riscv64.img" "$$app/rv64linux/Image"; \
		cp -a "$$app" "$(THEOS_OBJ_DIR)/ipa/Payload/"
	@cd "$(THEOS_OBJ_DIR)/ipa" && zip -qry "$(abspath $(THEOS_PACKAGE_DIR)/$(APPLICATION_NAME).ipa)" Payload
	@echo "built $(THEOS_PACKAGE_DIR)/$(APPLICATION_NAME).ipa"
