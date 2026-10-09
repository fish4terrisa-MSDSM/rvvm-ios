TARGET := iphone:clang:latest:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = rvvm

RVVM_DIR ?= RVVM

# Fetch upstream RVVM at the pinned commit and apply patches/*.patch.
# Runs at parse time because the source lists below are wildcards.
$(shell sh scripts/prepare-rvvm.sh "$(RVVM_DIR)" 1>&2)

# RVVM sources compiled into the app. This is upstream's librvvm object set
# minus the desktop-only parts: GUI backends, the standalone main, the user-mode
# runner, the Linux TAP/ALSA/VFIO backends, and the isolation hook.
RVVM_CORE = gdbstub rvvm rvvm_blk rvvm_fbdev rvvm_fdt rvvm_irq rvvm_isolation rvvm_pci rvvm_region rvvm_snapshot
RVVM_DEVICES = \
	bochs-display chardev_term eth-oc framebuffer hid-keyboard hid-mouse i2c-hid i2c-oc \
	ns16550a nvme ps2-altera ps2-keyboard ps2-mouse riscv-aclint riscv-plic syscon \
	rtc-goldfish rtl8169 tap_user virtio-fs virtio-gpu virtio-input

rvvm_FILES = \
	main.m \
	RV64AppDelegate.m \
	RV64RootViewController.m \
	RV64DisksViewController.m \
	RV64JIT.m \
	RV64Runner.mm \
	$(foreach f,$(RVVM_CORE),$(RVVM_DIR)/src/core/$(f).c) \
	$(wildcard $(RVVM_DIR)/src/cpu/*.c) \
	$(wildcard $(RVVM_DIR)/src/util/*.c) \
	$(wildcard $(RVVM_DIR)/src/rvjit/*.c) \
	$(foreach f,$(RVVM_DEVICES),$(RVVM_DIR)/src/devices/$(f).c)

rvvm_FRAMEWORKS = UIKit Foundation WebKit AVFoundation
rvvm_LIBRARIES = pthread

rvvm_CFLAGS = -fobjc-arc
rvvm_CFLAGS += -O3
rvvm_CFLAGS += -std=gnu11
rvvm_CFLAGS += -DUSE_JIT
rvvm_CFLAGS += -Wno-error=ignored-pragmas
rvvm_CFLAGS += -DNDEBUG -DUSE_RV64 -DUSE_FDT -DUSE_FPU -DUSE_NET
rvvm_CFLAGS += $(RVVM_INCFLAGS)

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
	$(RVVM_INCFLAGS)

rvvm_OBJCCFLAGS = $(rvvm_CCFLAGS)

# Upstream sources include sibling headers by bare name, so every subdirectory is on the path.
RVVM_INCFLAGS = -I$(RVVM_DIR)/include $(patsubst %,-I%,$(wildcard $(RVVM_DIR)/src $(RVVM_DIR)/src/*/))

rvvm_RESOURCE_DIRS = Resources

# JIT (StikDebug enables it at runtime) and increased memory limit need entitlements.
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

before-all:: xterm-assets

.PHONY: ipa
ipa: all
	@rm -rf "$(THEOS_OBJ_DIR)/ipa" "$(THEOS_PACKAGE_DIR)/$(APPLICATION_NAME).ipa"
	@mkdir -p "$(THEOS_OBJ_DIR)/ipa/Payload" "$(THEOS_PACKAGE_DIR)"
	@rm -f "$(THEOS_OBJ_DIR)/$(APPLICATION_NAME).app/rv64linux/alpine-standard-3.23.3-riscv64.iso"
	@rm -f "$(THEOS_OBJ_DIR)/$(APPLICATION_NAME).app/rv64linux/alpine-riscv64.img"
	@rm -f "$(THEOS_OBJ_DIR)/$(APPLICATION_NAME).app/rv64linux/Image"
	@cp -a "$(THEOS_OBJ_DIR)/$(APPLICATION_NAME).app" "$(THEOS_OBJ_DIR)/ipa/Payload/"
	@cd "$(THEOS_OBJ_DIR)/ipa" && zip -qry "$(abspath $(THEOS_PACKAGE_DIR)/$(APPLICATION_NAME).ipa)" Payload
