#import "RV64Runner.h"

#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

#include <rvvm/rvvm.h>
#include <rvvm/rvvm_blk.h>
#include <rvvm/rvvm_board.h>
#include <rvvm/rvvm_fb.h>
#include <rvvm/rvvm_pci.h>

extern "C" {
#include "devices/chardev.h"
#include "devices/framebuffer.h"
#include "devices/hid_api.h"
#include "devices/i2c-oc.h"
#include "devices/ns16550a.h"
#include "devices/rtl8169.h"
#include "devices/tap_api.h"
#include "devices/virtio-fs.h"
#include "devices/virtio-gpu.h"
}

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fcntl.h>
#include <limits.h>
#include <mutex>
#include <sys/stat.h>
#include <string>
#include <unistd.h>
#include <vector>

NSString *const RV64RunnerUARTTextNotification = @"RV64RunnerUARTTextNotification";
NSString *const RV64RunnerUARTTextKey = @"text";
NSString *const RV64RunnerVirtioFSDebugNotification = @"RV64RunnerVirtioFSDebugNotification";
NSString *const RV64RunnerFramebufferNotification = @"RV64RunnerFramebufferNotification";
NSString *const RV64RunnerFramebufferDataKey = @"data";
NSString *const RV64RunnerFramebufferWidthKey = @"width";
NSString *const RV64RunnerFramebufferHeightKey = @"height";
NSString *const RV64RunnerFramebufferStrideKey = @"stride";
NSString *const RV64RunnerFramebufferFormatKey = @"format";

static std::atomic<uint32_t> s_fb_seq(0);
static std::atomic<uint32_t> s_fb_width(0);
static std::atomic<uint32_t> s_fb_height(0);
static std::atomic<uint32_t> s_fb_stride(0);
static std::atomic<uint32_t> s_fb_format(0);
static std::atomic<uint32_t> s_fb_offset(0);

static NSString *const kRVVMDefaultsBootMode = @"rvvm.bootMode";
static NSString *const kRVVMDefaultsCores = @"rvvm.cores";
static NSString *const kRVVMDefaultsRamMB = @"rvvm.ramMB";
static NSString *const kRVVMDefaultsDisableIso = @"rvvm.disableIso";
static NSString *const kRVVMDefaultsIsoFilename = @"rvvm.isoFilename";
static NSString *const kRVVMDefaultsDiskFilename = @"rvvm.diskFilename";
static NSString *const kRVVMDefaultsDisks = @"rvvm.disks";
static NSString *const kRVVMDefaultsArchImgFilename = @"rvvm.archImgFilename";
static NSString *const kRVVMDefaultsPortForwards = @"rvvm.portForwards";
static NSString *const kRVVMDefaultsVirtioFSDebugToUART = @"rvvm.virtiofsDebugToUart";
static NSString *const kRVVMDefaultsAutoLoadSnapshot = @"rvvm.autoLoadSnapshot";
static NSString *const kRVVMDefaultsExtraDisks = @"rvvm.extraDisks";
static NSString *const kRVVMDefaultsShares = @"rvvm.shares";
static NSString *const kRVVMDefaultsFirmwareFilename = @"rvvm.firmwareFilename";
static NSString *const kRVVMDefaultsGPUMode = @"rvvm.gpuMode";

// Framebuffer VRAM shared by bochs-display, simplefb and virtio-gpu (covers 4K XRGB).
static const size_t kIOSFramebufferVRAMBytes = (size_t)32 << 20;

typedef NS_ENUM(NSInteger, RVVMBootMode) {
	RVVMBootModeAuto = 0,
	RVVMBootModeAlpine = 1,
	RVVMBootModeArch = 2,
	RVVMBootModeCustom = 3,
};

// Console log in Documents/logs/console.log (visible in the Files app). Rotates at 4 MB to console.log.1.
// Writes happen on a serial queue so the VM threads never block on disk.
static void AppendConsoleLog(const std::string& s)
{
	if (s.empty()) {
		return;
	}
	static dispatch_queue_t logQueue = dispatch_queue_create("com.adih.rvvm.log", DISPATCH_QUEUE_SERIAL);
	NSData *data = [NSData dataWithBytes:s.data() length:s.size()];
	dispatch_async(logQueue, ^{
		NSFileManager *fm = NSFileManager.defaultManager;
		NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
		if (!docs) {
			return;
		}
		NSString *dir = [docs stringByAppendingPathComponent:@"logs"];
		[fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
		NSString *path = [dir stringByAppendingPathComponent:@"console.log"];
		NSNumber *size = [fm attributesOfItemAtPath:path error:nil][NSFileSize];
		if (size.unsignedLongLongValue > (4ULL << 20)) {
			NSString *old = [path stringByAppendingString:@".1"];
			[fm removeItemAtPath:old error:nil];
			[fm moveItemAtPath:path toPath:old error:nil];
		}
		if (![fm fileExistsAtPath:path]) {
			[fm createFileAtPath:path contents:nil attributes:nil];
		}
		NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
		if (!fh) {
			return;
		}
		[fh seekToEndOfFileWithError:nil];
		[fh writeData:data error:nil];
		[fh closeAndReturnError:nil];
	});
}

static void PostUARTText(const std::string& s)
{
	AppendConsoleLog(s);
	CFStringRef cfText = CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)s.data(), (CFIndex)s.size(),
	                                            kCFStringEncodingUTF8, false);
	NSString *text = cfText ? (__bridge_transfer NSString *)cfText : nil;
	if (!text || text.length == 0) {
		return;
	}
	dispatch_async(dispatch_get_main_queue(), ^{
		[[NSNotificationCenter defaultCenter] postNotificationName:RV64RunnerUARTTextNotification object:text userInfo:nil];
	});
}

static void PostVirtioFSDebugText(const std::string& s)
{
	AppendConsoleLog(s);
	CFStringRef cfText = CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)s.data(), (CFIndex)s.size(),
	                                            kCFStringEncodingUTF8, false);
	NSString *text = cfText ? (__bridge_transfer NSString *)cfText : nil;
	if (!text || text.length == 0) {
		return;
	}
	dispatch_async(dispatch_get_main_queue(), ^{
		[[NSNotificationCenter defaultCenter] postNotificationName:RV64RunnerVirtioFSDebugNotification object:text userInfo:nil];
	});
}

static std::mutex s_vfs_debug_mu;
static std::deque<std::string> s_vfs_debug_lines;
static size_t s_vfs_debug_bytes = 0;
static std::atomic<bool> s_vfs_debug_to_uart(true);

static void AppendVirtioFSDebugLine(const std::string& s)
{
	constexpr size_t kMaxLines = 1000;
	constexpr size_t kMaxBytes = 256 * 1024;
	std::lock_guard<std::mutex> lock(s_vfs_debug_mu);
	s_vfs_debug_lines.push_back(s);
	s_vfs_debug_bytes += s.size();
	while (!s_vfs_debug_lines.empty() && (s_vfs_debug_lines.size() > kMaxLines || s_vfs_debug_bytes > kMaxBytes)) {
		s_vfs_debug_bytes -= s_vfs_debug_lines.front().size();
		s_vfs_debug_lines.pop_front();
	}
}

extern "C" void rvvm_ios_uart_debug_print(const char* s) __attribute__((used));
extern "C" void rvvm_ios_uart_debug_print(const char* s)
{
	if (!s) {
		return;
	}
	PostUARTText(std::string(s));
}

extern "C" void rvvm_ios_virtiofs_debug_print(const char* s) __attribute__((used));
extern "C" void rvvm_ios_virtiofs_debug_print(const char* s)
{
	if (!s) {
		return;
	}
	std::string str(s);
	AppendVirtioFSDebugLine(str);
	PostVirtioFSDebugText(str);
	if (s_vfs_debug_to_uart.load()) {
		PostUARTText(str);
	}
}

static void IOSFBDraw(rvvm_fbdev_t* fbdev)
{
	if (!fbdev) {
		return;
	}

	rvvm_fb_t fb = {};
	if (!rvvm_fbdev_get_scanout(fbdev, &fb) || !fb.buffer || fb.width == 0 || fb.height == 0 || fb.stride == 0) {
		return;
	}
	size_t vramSize = 0;
	uint8_t* vram = (uint8_t *)rvvm_fbdev_get_vram(fbdev, &vramSize);
	if (!vram || vramSize == 0) {
		return;
	}
	uintptr_t off = (uintptr_t)fb.buffer - (uintptr_t)vram;
	if (off >= vramSize || off > UINT32_MAX) {
		return;
	}

	s_fb_width.store(fb.width, std::memory_order_relaxed);
	s_fb_height.store(fb.height, std::memory_order_relaxed);
	s_fb_stride.store(fb.stride, std::memory_order_relaxed);
	s_fb_format.store((uint32_t)fb.format, std::memory_order_relaxed);
	s_fb_offset.store((uint32_t)off, std::memory_order_relaxed);
	(void)s_fb_seq.fetch_add(1, std::memory_order_relaxed);
}

static const rvvm_display_cb_t s_ios_display_cb = {
	.draw = IOSFBDraw,
};

static std::string FileSystemPath(NSURL *url)
{
	if (!url) {
		return {};
	}

	CFURLRef cfURL = (__bridge CFURLRef)url;
	if (!cfURL) {
		return {};
	}

	CFStringRef cfPath = CFURLCopyFileSystemPath(cfURL, kCFURLPOSIXPathStyle);
	if (!cfPath) {
		return {};
	}

	char buf[PATH_MAX];
	Boolean ok = CFStringGetCString(cfPath, buf, sizeof(buf), kCFStringEncodingUTF8);
	CFRelease(cfPath);
	if (!ok) {
		return {};
	}
	return std::string(buf);
}

static std::mutex s_state_mutex;
static dispatch_source_t s_uart_flush_timer;
static dispatch_once_t s_uart_flush_once;
static rvvm_machine_t* s_machine = nullptr;
static chardev_t* s_chardev = nullptr;
static tap_dev_t* s_tap = nullptr;
static hid_keyboard_t* s_uart_keyboard_virtio = nullptr;
static hid_mouse_t* s_mouse_virtio = nullptr;
static std::atomic<uint32_t> s_mouse_abs_width(0);
static std::atomic<uint32_t> s_mouse_abs_height(0);
static rvvm_fbdev_t* s_fbdev = nullptr;
static std::vector<uint8_t> s_fb_vram;
static dispatch_semaphore_t s_restart_sema;
static dispatch_once_t s_restart_once;
static std::atomic<bool> s_restart_requested(false);
static dispatch_semaphore_t s_snapshot_done_sema;
static dispatch_once_t s_snapshot_once;
static std::atomic<int> s_snapshot_op(0);
static std::mutex s_snapshot_result_mu;
static bool s_snapshot_result_ok = false;
static std::string s_snapshot_result_msg;
static std::string s_active_writable_disk_path;
static dispatch_semaphore_t s_network_done_sema;
static dispatch_once_t s_network_once;
static std::atomic<int> s_network_op(0);
static std::mutex s_network_result_mu;
static bool s_network_result_ok = false;
static std::string s_network_result_msg;

static void EnsureSnapshotPrimitives()
{
	dispatch_once(&s_snapshot_once, ^{
		s_snapshot_done_sema = dispatch_semaphore_create(0);
	});
}

static void SetSnapshotResult(bool ok, const std::string& msg)
{
	{
		std::lock_guard<std::mutex> lock(s_snapshot_result_mu);
		s_snapshot_result_ok = ok;
		s_snapshot_result_msg = msg;
	}
	dispatch_semaphore_signal(s_snapshot_done_sema);
}

static void EnsureRestartSemaphore()
{
	dispatch_once(&s_restart_once, ^{
		s_restart_sema = dispatch_semaphore_create(0);
	});
}

static void EnsureNetworkPrimitives()
{
	dispatch_once(&s_network_once, ^{
		s_network_done_sema = dispatch_semaphore_create(0);
	});
}

static void SetNetworkResult(bool ok, const std::string& msg)
{
	{
		std::lock_guard<std::mutex> lock(s_network_result_mu);
		s_network_result_ok = ok;
		s_network_result_msg = msg;
	}
	dispatch_semaphore_signal(s_network_done_sema);
}

struct UIKitChardevState
{
	std::mutex mu;
	std::deque<uint8_t> rx;
	std::string tx_buf;
	CFAbsoluteTime lastPost = 0;
};

static bool MapAsciiToHidKey(uint8_t c, hid_key_t* keyOut, bool* shiftOut, bool* ctrlOut)
{
	if (!keyOut || !shiftOut || !ctrlOut) {
		return false;
	}
	*shiftOut = false;
	*ctrlOut = false;

	if (c >= 1 && c <= 26) {
		*ctrlOut = true;
		*keyOut = (hid_key_t)(HID_KEY_A + (c - 1));
		return true;
	}

	if (c >= 'a' && c <= 'z') {
		*keyOut = (hid_key_t)(HID_KEY_A + (c - 'a'));
		return true;
	}

	if (c >= 'A' && c <= 'Z') {
		*keyOut = (hid_key_t)(HID_KEY_A + (c - 'A'));
		*shiftOut = true;
		return true;
	}

	if (c >= '1' && c <= '9') {
		*keyOut = (hid_key_t)(HID_KEY_1 + (c - '1'));
		return true;
	}
	if (c == '0') {
		*keyOut = HID_KEY_0;
		return true;
	}

	switch (c) {
		case '\n': *keyOut = HID_KEY_ENTER; return true;
		case '\t': *keyOut = HID_KEY_TAB; return true;
		case 0x08: *keyOut = HID_KEY_BACKSPACE; return true;
		case 0x7f: *keyOut = HID_KEY_BACKSPACE; return true;
		case ' ':  *keyOut = HID_KEY_SPACE; return true;
		case '-':  *keyOut = HID_KEY_MINUS; return true;
		case '_':  *keyOut = HID_KEY_MINUS; *shiftOut = true; return true;
		case '=':  *keyOut = HID_KEY_EQUAL; return true;
		case '+':  *keyOut = HID_KEY_EQUAL; *shiftOut = true; return true;
		case '[':  *keyOut = HID_KEY_LEFTBRACE; return true;
		case '{':  *keyOut = HID_KEY_LEFTBRACE; *shiftOut = true; return true;
		case ']':  *keyOut = HID_KEY_RIGHTBRACE; return true;
		case '}':  *keyOut = HID_KEY_RIGHTBRACE; *shiftOut = true; return true;
		case '\\': *keyOut = HID_KEY_BACKSLASH; return true;
		case '|':  *keyOut = HID_KEY_BACKSLASH; *shiftOut = true; return true;
		case ';':  *keyOut = HID_KEY_SEMICOLON; return true;
		case ':':  *keyOut = HID_KEY_SEMICOLON; *shiftOut = true; return true;
		case '\'': *keyOut = HID_KEY_APOSTROPHE; return true;
		case '"':  *keyOut = HID_KEY_APOSTROPHE; *shiftOut = true; return true;
		case '`':  *keyOut = HID_KEY_GRAVE; return true;
		case '~':  *keyOut = HID_KEY_GRAVE; *shiftOut = true; return true;
		case ',':  *keyOut = HID_KEY_COMMA; return true;
		case '<':  *keyOut = HID_KEY_COMMA; *shiftOut = true; return true;
		case '.':  *keyOut = HID_KEY_DOT; return true;
		case '>':  *keyOut = HID_KEY_DOT; *shiftOut = true; return true;
		case '/':  *keyOut = HID_KEY_SLASH; return true;
		case '?':  *keyOut = HID_KEY_SLASH; *shiftOut = true; return true;
		case '!':  *keyOut = HID_KEY_1; *shiftOut = true; return true;
		case '@':  *keyOut = HID_KEY_2; *shiftOut = true; return true;
		case '#':  *keyOut = HID_KEY_3; *shiftOut = true; return true;
		case '$':  *keyOut = HID_KEY_4; *shiftOut = true; return true;
		case '%':  *keyOut = HID_KEY_5; *shiftOut = true; return true;
		case '^':  *keyOut = HID_KEY_6; *shiftOut = true; return true;
		case '&':  *keyOut = HID_KEY_7; *shiftOut = true; return true;
		case '*':  *keyOut = HID_KEY_8; *shiftOut = true; return true;
		case '(':  *keyOut = HID_KEY_9; *shiftOut = true; return true;
		case ')':  *keyOut = HID_KEY_0; *shiftOut = true; return true;
		default:   return false;
	}
}

static void InjectHidKeyVirtio(hid_keyboard_t* kb, hid_key_t key, bool shift, bool ctrl, bool alt)
{
	if (!kb) {
		return;
	}
	if (ctrl) {
		hid_keyboard_press_virtio(kb, HID_KEY_LEFTCTRL);
	}
	if (shift) {
		hid_keyboard_press_virtio(kb, HID_KEY_LEFTSHIFT);
	}
	if (alt) {
		hid_keyboard_press_virtio(kb, HID_KEY_LEFTALT);
	}
	hid_keyboard_press_virtio(kb, key);
	hid_keyboard_release_virtio(kb, key);
	if (alt) {
		hid_keyboard_release_virtio(kb, HID_KEY_LEFTALT);
	}
	if (shift) {
		hid_keyboard_release_virtio(kb, HID_KEY_LEFTSHIFT);
	}
	if (ctrl) {
		hid_keyboard_release_virtio(kb, HID_KEY_LEFTCTRL);
	}
}

static void EnsureUARTFlushTimerStarted()
{
	dispatch_once(&s_uart_flush_once, ^{
		s_uart_flush_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
		if (!s_uart_flush_timer) {
			return;
		}
		dispatch_source_set_timer(s_uart_flush_timer,
		                         dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)),
		                         (uint64_t)(50 * NSEC_PER_MSEC),
		                         (uint64_t)(5 * NSEC_PER_MSEC));
		dispatch_source_set_event_handler(s_uart_flush_timer, ^{
			chardev_t* dev = nullptr;
			{
				std::lock_guard<std::mutex> lock(s_state_mutex);
				dev = s_chardev;
			}
			auto* state = (dev && dev->data) ? (UIKitChardevState *)dev->data : nullptr;
			if (!state) {
				return;
			}
			std::string out;
			{
				std::lock_guard<std::mutex> lock(state->mu);
				if (state->tx_buf.empty()) {
					return;
				}
				state->lastPost = CFAbsoluteTimeGetCurrent();
				out = std::move(state->tx_buf);
				state->tx_buf.clear();
			}
			if (!out.empty()) {
				PostUARTText(out);
			}
		});
		dispatch_resume(s_uart_flush_timer);
	});
}

static uint32_t UIKitChardevPoll(chardev_t* dev)
{
	auto* state = dev ? (UIKitChardevState *)dev->data : nullptr;
	if (!state) {
		return CHARDEV_TX;
	}
	std::lock_guard<std::mutex> lock(state->mu);
	uint32_t flags = CHARDEV_TX;
	if (!state->rx.empty()) {
		flags |= CHARDEV_RX;
	}
	return flags;
}

static size_t UIKitChardevRead(chardev_t* dev, void* buf, size_t nbytes)
{
	auto* state = dev ? (UIKitChardevState *)dev->data : nullptr;
	if (!state || !buf || nbytes == 0) {
		return 0;
	}
	std::lock_guard<std::mutex> lock(state->mu);
	size_t n = 0;
	auto* out = (uint8_t *)buf;
	while (n < nbytes && !state->rx.empty()) {
		out[n++] = state->rx.front();
		state->rx.pop_front();
	}
	return n;
}

static size_t UIKitChardevWrite(chardev_t* dev, const void* buf, size_t nbytes)
{
	auto* state = dev ? (UIKitChardevState *)dev->data : nullptr;
	if (!state || !buf || nbytes == 0) {
		return nbytes;
	}

	std::vector<std::string> posts;
	posts.reserve(4);

	std::unique_lock<std::mutex> lock(state->mu);
	const auto* in = (const uint8_t *)buf;
	for (size_t i = 0; i < nbytes; i++) {
		uint8_t c = in[i];
		state->tx_buf.push_back((char)c);
		if (c == '\n' || c == '\r' || state->tx_buf.size() >= 1024) {
			posts.push_back(std::move(state->tx_buf));
			state->tx_buf.clear();
		}
	}

	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if (!state->tx_buf.empty() && (state->lastPost == 0 || (now - state->lastPost) >= (1.0 / 60.0))) {
		state->lastPost = now;
		posts.push_back(std::move(state->tx_buf));
		state->tx_buf.clear();
	}
	lock.unlock();

	for (const auto& s : posts) {
		if (!s.empty()) {
			PostUARTText(s);
		}
	}
	return nbytes;
}

static void UIKitChardevRemove(chardev_t* dev)
{
	if (!dev) {
		return;
	}
	auto* state = (UIKitChardevState *)dev->data;
	if (state) {
		std::string tail;
		{
			std::lock_guard<std::mutex> lock(state->mu);
			tail = std::move(state->tx_buf);
			state->tx_buf.clear();
			state->rx.clear();
		}
		if (!tail.empty()) {
			PostUARTText(tail);
		}
		delete state;
		dev->data = nullptr;
	}
	free(dev);
}

static chardev_t* CreateUIKitChardev()
{
	chardev_t* dev = (chardev_t *)calloc(1, sizeof(chardev_t));
	if (!dev) {
		return nullptr;
	}
	dev->poll = UIKitChardevPoll;
	dev->read = UIKitChardevRead;
	dev->write = UIKitChardevWrite;
	dev->remove = UIKitChardevRemove;
	dev->data = new UIKitChardevState();
	EnsureUARTFlushTimerStarted();
	return dev;
}

static std::string UTF8FromNSString(NSString *str)
{
	if (!str) {
		return {};
	}
	CFStringRef cf = (__bridge CFStringRef)str;
	if (!cf) {
		return {};
	}
	CFIndex length = CFStringGetLength(cf);
	if (length <= 0) {
		return {};
	}
	CFIndex maxBytes = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
	std::string out;
	out.resize((size_t)maxBytes);
	if (!CFStringGetCString(cf, out.data(), (CFIndex)out.size(), kCFStringEncodingUTF8)) {
		return {};
	}
	out.resize(strlen(out.c_str()));
	return out;
}

static bool EnsureSparseRawImage(const std::string& path, size_t preferredSize, size_t* actualSizeOut)
{
	if (path.empty() || preferredSize == 0) {
		return false;
	}

	struct stat st;
	if (stat(path.c_str(), &st) == 0 && (size_t)st.st_size >= preferredSize) {
		if (actualSizeOut) {
			*actualSizeOut = (size_t)st.st_size;
		}
		return true;
	}

	int fd = open(path.c_str(), O_RDWR | O_CREAT, 0644);
	if (fd < 0) {
		return false;
	}
	int ok = ftruncate(fd, (off_t)preferredSize);
	close(fd);
	if (ok != 0) {
		return false;
	}
	if (actualSizeOut) {
		*actualSizeOut = preferredSize;
	}
	return true;
}

static NSString *NSStringFromUTF8String(const std::string& s)
{
	if (s.empty()) {
		return nil;
	}
	CFStringRef cf = CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)s.data(), (CFIndex)s.size(), kCFStringEncodingUTF8, false);
	return cf ? (__bridge_transfer NSString *)cf : nil;
}

static bool PathExists(const std::string& path)
{
	if (path.empty()) {
		return false;
	}
	struct stat st;
	return (stat(path.c_str(), &st) == 0);
}

static std::string SnapshotFilePathUTF8()
{
	@autoreleasepool {
		NSArray<NSString *> *docsDirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
		NSString *docsDirPath = (docsDirs.count > 0) ? [docsDirs objectAtIndex:0] : nil;
		std::string docsPathUTF8 = UTF8FromNSString(docsDirPath);
		if (!docsPathUTF8.empty() && docsPathUTF8.back() == '/') {
			docsPathUTF8.pop_back();
		}
		if (docsPathUTF8.empty()) {
			return {};
		}
		return docsPathUTF8 + "/rvvm.snapshot.img";
	}
}

static std::string SnapshotMetaPathUTF8()
{
	std::string snap = SnapshotFilePathUTF8();
	if (snap.empty()) {
		return {};
	}
	return snap.substr(0, snap.size() - strlen("rvvm.snapshot.img")) + "rvvm.snapshot.meta";
}

struct RvvmSnapshotHeader
{
	char magic[8];
	uint32_t version;
	uint32_t flags;
	uint64_t mem_addr;
	uint64_t mem_size;
	uint32_t hart_count;
	uint32_t reserved;
	uint64_t timer_freq;
	uint64_t timer_time;
};

static bool ReadRvvmSnapshotHeader(const std::string& path, RvvmSnapshotHeader* out)
{
	if (!out || path.empty()) {
		return false;
	}
	int fd = open(path.c_str(), O_RDONLY);
	if (fd < 0) {
		return false;
	}
	ssize_t n = read(fd, out, sizeof(*out));
	close(fd);
	if (n != (ssize_t)sizeof(*out)) {
		return false;
	}
	if (memcmp(out->magic, "RVVMSNAP", 8) != 0) {
		return false;
	}
	if (out->version != 1 || out->reserved != 0) {
		return false;
	}
	return true;
}

static bool WriteRvvmSnapshotHeader(const std::string& path, const RvvmSnapshotHeader& hdr)
{
	int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		return false;
	}
	ssize_t n = write(fd, &hdr, sizeof(hdr));
	close(fd);
	return n == (ssize_t)sizeof(hdr);
}

// Upstream snapshots are block-device based: the machine state is streamed into snapPath.
static bool SaveMachineSnapshot(rvvm_machine_t* machine, const std::string& snapPath)
{
	rvvm_blk_dev_t* blk = rvvm_blk_open(snapPath.c_str(), NULL, RVVM_BLK_RW | RVVM_BLK_CREAT | RVVM_BLK_TRUNC);
	if (!blk) {
		return false;
	}
	bool ok = rvvm_machine_snapshot(machine, blk, true);
	rvvm_blk_close(blk);
	return ok;
}

static bool LoadMachineSnapshot(rvvm_machine_t* machine, const std::string& snapPath)
{
	rvvm_blk_dev_t* blk = rvvm_blk_open(snapPath.c_str(), NULL, RVVM_BLK_READ);
	if (!blk) {
		return false;
	}
	bool ok = rvvm_machine_snapshot(machine, blk, false);
	rvvm_blk_close(blk);
	return ok;
}

// Attach a raw image as an NVMe disk. Read-only images are opened without write access.
// Ordered list of Documents-relative disk names to attach (rvvm.disks). Settings written before this key
// existed used rvvm.diskFilename (primary) plus rvvm.extraDisks; those are migrated here.
static NSArray<NSString *> *OrderedDiskNames(NSUserDefaults *defaults)
{
	NSArray<NSString *> *ordered = [defaults arrayForKey:kRVVMDefaultsDisks];
	if (ordered) {
		return ordered;
	}
	NSMutableArray<NSString *> *legacy = [NSMutableArray array];
	NSString *primary = [defaults stringForKey:kRVVMDefaultsDiskFilename];
	if (primary.length > 0) {
		[legacy addObject:primary];
	}
	for (NSString *name in [defaults arrayForKey:kRVVMDefaultsExtraDisks] ?: @[]) {
		if (![legacy containsObject:name]) {
			[legacy addObject:name];
		}
	}
	return legacy;
}

static bool AttachNVMeDisk(rvvm_machine_t* machine, const std::string& path, bool readOnly)
{
	uint32_t opts = readOnly ? RVVM_BLK_READ : RVVM_BLK_RW;
	rvvm_blk_dev_t* blk = rvvm_blk_open(path.c_str(), NULL, opts);
	if (!blk) {
		return false;
	}
	return rvvm_nvme_init(machine, blk, RVVM_PCI_ADDR_ANY) != NULL;
}

// ---- Sparse raw images -----------------------------------------------------
// RVVM only supports raw images. Images are created and copied with holes so
// that a 64 GiB disk only occupies the blocks that were actually written.

static bool SetErrorString(NSString * _Nullable * _Nullable errorOut, NSString *msg)
{
	if (errorOut) {
		*errorOut = msg;
	}
	return NO;
}

static const size_t kSparseChunk = (size_t)1 << 20;

// Copy src to dst, skipping all-zero chunks so the destination stays sparse.
static bool SparseCopyFile(const std::string& src, const std::string& dst, uint64_t* sizeOut)
{
	int in = open(src.c_str(), O_RDONLY);
	if (in < 0) {
		return false;
	}
	struct stat st;
	if (fstat(in, &st) != 0) {
		close(in);
		return false;
	}
	int out = open(dst.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (out < 0) {
		close(in);
		return false;
	}
	std::vector<uint8_t> buf(kSparseChunk);
	bool ok = true;
	off_t off = 0;
	while (off < st.st_size) {
		size_t want = (size_t)std::min<off_t>((off_t)kSparseChunk, st.st_size - off);
		ssize_t got = pread(in, buf.data(), want, off);
		if (got <= 0) {
			ok = (got == 0);
			break;
		}
		bool zero = true;
		for (ssize_t i = 0; i < got && zero; i++) {
			zero = (buf[(size_t)i] == 0);
		}
		if (!zero) {
			ssize_t put = pwrite(out, buf.data(), (size_t)got, off);
			if (put != got) {
				ok = false;
				break;
			}
		}
		off += got;
	}
	if (ok && ftruncate(out, st.st_size) != 0) {
		ok = false;
	}
	close(in);
	close(out);
	if (ok && sizeOut) {
		*sizeOut = (uint64_t)st.st_size;
	}
	return ok;
}

static bool CreateSparseImage(const std::string& path, uint64_t size)
{
	int fd = open(path.c_str(), O_RDWR | O_CREAT | O_EXCL, 0644);
	if (fd < 0) {
		return false;
	}
	bool ok = (ftruncate(fd, (off_t)size) == 0);
	close(fd);
	return ok;
}

static bool ExpandSparseImage(const std::string& path, uint64_t newSize)
{
	struct stat st;
	if (stat(path.c_str(), &st) != 0 || (uint64_t)st.st_size > newSize) {
		return false;   // RVVM images cannot shrink safely; growing only
	}
	int fd = open(path.c_str(), O_RDWR);
	if (fd < 0) {
		return false;
	}
	bool ok = (ftruncate(fd, (off_t)newSize) == 0);
	close(fd);
	return ok;
}

// Rewrite an existing raw image so all-zero regions become holes.
static bool SparsifyImage(const std::string& path)
{
	std::string tmp = path + ".sparse-tmp";
	uint64_t size = 0;
	if (!SparseCopyFile(path, tmp, &size)) {
		unlink(tmp.c_str());
		return false;
	}
	if (rename(tmp.c_str(), path.c_str()) != 0) {
		unlink(tmp.c_str());
		return false;
	}
	return true;
}

#if defined(USE_FPU)
#define USE_FPU_FLAG 1
#else
#define USE_FPU_FLAG 0
#endif

static bool RunLinuxOnce()
{
	@autoreleasepool {
		NSBundle *bundle = [NSBundle mainBundle];
		NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
		NSInteger cores = [defaults integerForKey:kRVVMDefaultsCores];
		NSInteger ramMB = [defaults integerForKey:kRVVMDefaultsRamMB];
		BOOL disableIso = [defaults boolForKey:kRVVMDefaultsDisableIso];
		NSString *isoFilename = [defaults stringForKey:kRVVMDefaultsIsoFilename];
		NSArray *portForwards = (NSArray *)[defaults objectForKey:kRVVMDefaultsPortForwards];
		id vfsDbgObj = [defaults objectForKey:kRVVMDefaultsVirtioFSDebugToUART];
		BOOL virtioFSDebugToUart = vfsDbgObj ? [defaults boolForKey:kRVVMDefaultsVirtioFSDebugToUART] : YES;
		id autoSnapObj = [defaults objectForKey:kRVVMDefaultsAutoLoadSnapshot];
		BOOL autoLoadSnapshot = autoSnapObj ? [defaults boolForKey:kRVVMDefaultsAutoLoadSnapshot] : YES;
		s_vfs_debug_to_uart.store(virtioFSDebugToUart);

		NSArray<NSString *> *docsDirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
		NSString *docsDirPath = (docsDirs.count > 0) ? [docsDirs objectAtIndex:0] : nil;
		std::string docsPathUTF8 = UTF8FromNSString(docsDirPath);
		if (!docsPathUTF8.empty() && docsPathUTF8.back() == '/') {
			docsPathUTF8.pop_back();
		}

		auto DocsFilePathIfExists = [&](NSString *filename) -> std::string {
			if (docsPathUTF8.empty() || filename.length == 0) {
				return {};
			}
			std::string name = UTF8FromNSString(filename);
			if (name.empty()) {
				return {};
			}
			std::string p = docsPathUTF8 + "/" + name;
			struct stat st;
			if (stat(p.c_str(), &st) != 0) {
				return {};
			}
			return p;
		};

		NSURL *fwPayloadURL = [bundle URLForResource:@"fw_payload" withExtension:@"bin" subdirectory:@"rv64linux"];

		std::string snapPath = SnapshotFilePathUTF8();
		std::string snapMetaPath = SnapshotMetaPathUTF8();
		RvvmSnapshotHeader snapHdr = {};
		bool haveSnapHeader = (!snapMetaPath.empty() && ReadRvvmSnapshotHeader(snapMetaPath, &snapHdr));
		bool haveSnap = haveSnapHeader && autoLoadSnapshot && PathExists(snapPath);

		// The ISO is user-imported only (no bundled ISO). Boot from it when set, otherwise boot the first disk.
		std::string isoPath;
		if (!disableIso && isoFilename.length > 0) {
			isoPath = DocsFilePathIfExists(isoFilename);
		}
		// Attached disks in the user's order. Names whose files are missing are skipped.
		std::vector<std::string> diskPaths;
		for (NSString *name in OrderedDiskNames(defaults)) {
			std::string p = DocsFilePathIfExists(name);
			if (!p.empty()) {
				diskPaths.push_back(p);
			}
		}
		if (!fwPayloadURL) {
			PostUARTText("rvvm: missing boot resources\n");
			return false;
		}
		bool useIso = !isoPath.empty();
		bool useDiskBoot = !useIso && !diskPaths.empty();
		if (!useIso && !useDiskBoot) {
			PostUARTText("rvvm: nothing to boot: import an ISO or attach a disk image\n");
			return false;
		}
		std::string firstDiskPath = diskPaths.empty() ? std::string() : diskPaths.front();

		NSURL *biosURL = fwPayloadURL;
		std::string biosPath = FileSystemPath(biosURL);
		NSString *fwName = [defaults stringForKey:kRVVMDefaultsFirmwareFilename];
		if (fwName.length > 0) {
			std::string userFw = DocsFilePathIfExists([@"firmware/" stringByAppendingString:fwName]);
			if (!userFw.empty()) {
				biosPath = userFw;
			} else {
				PostUARTText("rvvm: selected firmware missing, using bundled OpenSBI\n");
			}
		}

		size_t preferredMem = 0;
		if (haveSnap) {
			preferredMem = (size_t)snapHdr.mem_size;
		} else if (ramMB > 0) {
			preferredMem = (size_t)ramMB << 20;
		} else {
			preferredMem = useIso ? (size_t)(1ULL << 30) : (size_t)(2ULL << 30);
		}
		static const size_t fallbacks[] = {
			(size_t)(8ULL << 30),
			(size_t)(6ULL << 30),
			(size_t)(4ULL << 30),
			(size_t)(3ULL << 30),
			(size_t)(2ULL << 30),
			(size_t)(1536ULL << 20),
			(size_t)(1024ULL << 20),
			(size_t)(768ULL << 20),
			(size_t)(512ULL << 20),
			(size_t)(256ULL << 20),
		};

		rvvm_machine_t* machine = nullptr;
		size_t chosenMem = 0;
		size_t smp = 0;
		if (haveSnap) {
			smp = (size_t)std::min<uint32_t>(8, std::max<uint32_t>(1, snapHdr.hart_count));
		} else if (cores > 0) {
			smp = (size_t)std::min<NSInteger>(8, std::max<NSInteger>(1, cores));
		} else {
			smp = useIso ? 2 : 1;
		}

		if (preferredMem != 0) {
			machine = rvvm_create_machine(preferredMem, smp, "rv64gc");
			if (machine) {
				chosenMem = preferredMem;
			}
		}

		if (!machine) {
			for (size_t candidate : fallbacks) {
				if (candidate > preferredMem) {
					continue;
				}
				machine = rvvm_create_machine(candidate, smp, "rv64gc");
				if (machine) {
					chosenMem = candidate;
					break;
				}
			}
		}
		if (!machine) {
			PostUARTText("rvvm: rvvm_create_machine failed (RAM allocation)\n");
			return false;
		}
		rvvm_append_cmdline(machine, " console=ttyS0,115200 console=tty0 earlycon=sbi");

		chardev_t* chardev = CreateUIKitChardev();
		if (!chardev) {
			PostUARTText("rvvm: failed to create uart chardev\n");
			rvvm_free_machine(machine);
			return false;
		}

		// CLINT, PLIC, PCIe ECAM, syscon and goldfish RTC
		if (!rvvm_board_riscv_virt_init(machine, false)) {
			PostUARTText("rvvm: board init failed\n");
			chardev_free(chardev);
			rvvm_free_machine(machine);
			return false;
		}
		tap_dev_t* tap = nullptr;
		hid_keyboard_t* kbVirtio = hid_keyboard_init_auto_virtio(machine);
		hid_mouse_t* mouseVirtio = hid_mouse_init_auto_virtio(machine);

		rvvm_fbdev_t* fbdev = rvvm_fbdev_init();
		if (!fbdev) {
			PostUARTText("rvvm: fbdev init failed\n");
			chardev_free(chardev);
			rvvm_free_machine(machine);
			return false;
		}
		rvvm_fbdev_inc_ref(fbdev);
		std::vector<uint8_t> vram;
		vram.resize(kIOSFramebufferVRAMBytes);
		memset(vram.data(), 0, vram.size());
		(void)rvvm_fbdev_set_vram(fbdev, vram.data(), vram.size());
		{
			rvvm_fb_t bootFb = {};
			bootFb.width = 1280;
			bootFb.height = 720;
			bootFb.stride = bootFb.width * 4;
			bootFb.format = RVVM_RGB_XRGB8888;
			bootFb.buffer = vram.data();
			rvvm_fbdev_set_scanout(fbdev, &bootFb);
		}
		rvvm_fbdev_register_display(fbdev, &s_ios_display_cb);
		// gpuMode 1 = virtio-gpu 2D (3D backends are not built into this app yet).
		// Otherwise fall back to the simple framebuffer and bochs display.
		NSInteger gpuMode = [defaults integerForKey:kRVVMDefaultsGPUMode];
		if (gpuMode == 1) {
			if (!virtio_gpu_init_auto(machine, fbdev, 1280, 720)) {
				PostUARTText("rvvm: virtio-gpu init failed, using simplefb\n");
				(void)rvvm_simplefb_init_auto(machine, fbdev);
				(void)rvvm_bochs_display_init_auto(machine, fbdev);
			}
		} else {
			(void)rvvm_simplefb_init_auto(machine, fbdev);
			(void)rvvm_bochs_display_init_auto(machine, fbdev);
		}
		(void)i2c_oc_init_auto(machine);

		tap = tap_open();
		if (!tap) {
			PostUARTText("rvvm: tap open failed\n");
			chardev_free(chardev);
			rvvm_free_machine(machine);
			(void)rvvm_fbdev_dec_ref(fbdev);
			return false;
		}
		if (!rvvm_rtl8169_init(machine, tap, RVVM_PCI_ADDR_ANY)) {
			PostUARTText("rvvm: rtl8169 failed\n");
			tap_close(tap);
			chardev_free(chardev);
			rvvm_free_machine(machine);
			(void)rvvm_fbdev_dec_ref(fbdev);
			return false;
		}

		if (portForwards) {
			for (NSUInteger i = 0; i < portForwards.count; i++) {
				NSString *s = (NSString *)[portForwards objectAtIndex:i];
				if (!s || s.length == 0) {
					continue;
				}
				std::string fwd = UTF8FromNSString(s);
				if (fwd.empty()) {
					continue;
				}
				(void)tap_portfwd(tap, fwd.c_str());
			}
		}
		if (useIso) {
			if (!AttachNVMeDisk(machine, isoPath, true)) {
				PostUARTText("rvvm: nvme iso failed\n");
				if (tap) {
					tap_close(tap);
				}
				chardev_free(chardev);
				rvvm_free_machine(machine);
				(void)rvvm_fbdev_dec_ref(fbdev);
				return false;
			}
		}
		// Attached disks, in the order the user set in the Disks screen.
		for (const std::string& path : diskPaths) {
			if (!AttachNVMeDisk(machine, path, false)) {
				PostUARTText(("rvvm: disk attach failed: " + path + "\n").c_str());
			}
		}

		ns16550a_init_auto(machine, chardev);

		// Shared folders: each entry is a directory under Documents, mounted by its name.
		// Without entries, the whole Documents folder is shared as "share".
		NSArray<NSString *> *shares = [defaults arrayForKey:kRVVMDefaultsShares];
		BOOL sharesOn = [defaults objectForKey:@"rvvm.sharesEnabled"] ? [defaults boolForKey:@"rvvm.sharesEnabled"] : YES;
		if (!sharesOn) {
			// Sharing turned off in settings: no virtio-fs device is attached.
		} else if (shares.count > 0) {
			for (NSString *rel in shares) {
				std::string dir = DocsFilePathIfExists(rel);
				if (dir.empty()) {
					continue;
				}
				std::string tag = UTF8FromNSString([rel lastPathComponent]);
				if (tag.empty()) {
					continue;
				}
				if (!virtio_fs_init_auto(machine, tag.c_str(), dir.c_str())) {
					PostVirtioFSDebugText("rvvm: virtio-fs share failed: " + dir);
				}
			}
		} else if (!docsPathUTF8.empty()) {
			(void)virtio_fs_init_auto(machine, "share", docsPathUTF8.c_str());
		}

		if (!rvvm_load_firmware(machine, biosPath.c_str())) {
			PostUARTText("rvvm: load firmware failed\n");
			if (tap) {
				tap_close(tap);
			}
			chardev_free(chardev);
			rvvm_free_machine(machine);
			(void)rvvm_fbdev_dec_ref(fbdev);
			return false;
		}

		{
			if (haveSnap) {
#if defined(USE_FPU)
				const uint32_t expectedFlags = 0x1;
#else
				const uint32_t expectedFlags = 0x0;
#endif
				if ((snapHdr.flags & 0x1) == expectedFlags &&
				    snapHdr.mem_size == (uint64_t)chosenMem &&
				    snapHdr.hart_count == (uint32_t)smp) {
					if (!LoadMachineSnapshot(machine, snapPath)) {
						PostUARTText("rvvm: snapshot restore failed, booting fresh\n");
					}
				}
			}
		}

		{
			std::lock_guard<std::mutex> lock(s_state_mutex);
			s_machine = machine;
			s_chardev = chardev;
			s_tap = tap;
			s_uart_keyboard_virtio = kbVirtio;
			s_mouse_virtio = mouseVirtio;
			s_fbdev = fbdev;
			s_fb_vram.swap(vram);
			s_fb_seq.store(0, std::memory_order_relaxed);
			s_fb_width.store(0, std::memory_order_relaxed);
			s_fb_height.store(0, std::memory_order_relaxed);
			s_fb_stride.store(0, std::memory_order_relaxed);
			s_fb_format.store(0, std::memory_order_relaxed);
			s_fb_offset.store(0, std::memory_order_relaxed);
			s_active_writable_disk_path = firstDiskPath;
		}
		rvvm_start_machine(machine);
		for (;;) {
			rvvm_run_eventloop();
			int op = s_snapshot_op.exchange(0);
			if (op == 1) {
				std::string snapPath = SnapshotFilePathUTF8();
				if (snapPath.empty()) {
					SetSnapshotResult(false, "snapshot: path unavailable");
					rvvm_start_machine(machine);
					continue;
				}
				RvvmSnapshotHeader meta = {};
				memcpy(meta.magic, "RVVMSNAP", 8);
				meta.version = 1;
				meta.flags = (uint32_t)USE_FPU_FLAG;
				meta.mem_addr = 0x80000000ULL;
				meta.mem_size = (uint64_t)chosenMem;
				meta.hart_count = (uint32_t)smp;
				if (!SaveMachineSnapshot(machine, snapPath) || !WriteRvvmSnapshotHeader(SnapshotMetaPathUTF8(), meta)) {
					SetSnapshotResult(false, "snapshot save failed");
					rvvm_start_machine(machine);
					continue;
				}
				SetSnapshotResult(true, "snapshot saved");
				rvvm_start_machine(machine);
				continue;
			}
			if (op == 2) {
				std::string snapPath = SnapshotFilePathUTF8();
				if (snapPath.empty()) {
					SetSnapshotResult(false, "snapshot: path unavailable");
					rvvm_start_machine(machine);
					continue;
				}
				if (!PathExists(snapPath)) {
					SetSnapshotResult(false, "snapshot file not found");
					rvvm_start_machine(machine);
					continue;
				}
				if (!LoadMachineSnapshot(machine, snapPath)) {
					SetSnapshotResult(false, "snapshot load failed");
					rvvm_start_machine(machine);
					continue;
				}
				SetSnapshotResult(true, "snapshot loaded");
				rvvm_start_machine(machine);
				continue;
			}
			int netOp = s_network_op.exchange(0);
			if (netOp == 1) {
				if (!tap) {
					SetNetworkResult(false, "network: tap unavailable");
					rvvm_start_machine(machine);
					continue;
				}
				if (!tap_reinit(tap)) {
					SetNetworkResult(false, "network reinit failed");
					rvvm_start_machine(machine);
					continue;
				}
				SetNetworkResult(true, "network reinitialized");
				rvvm_start_machine(machine);
				continue;
			}
			break;
		}

		{
			std::lock_guard<std::mutex> lock(s_state_mutex);
			s_chardev = nullptr;
			s_machine = nullptr;
			s_tap = nullptr;
			s_uart_keyboard_virtio = nullptr;
			s_mouse_virtio = nullptr;
			s_mouse_abs_width.store(0, std::memory_order_relaxed);
			s_mouse_abs_height.store(0, std::memory_order_relaxed);
			s_fbdev = nullptr;
			s_active_writable_disk_path.clear();
		}
		if (tap) {
			tap_close(tap);
		}
		chardev_free(chardev);
		rvvm_free_machine(machine);
		(void)rvvm_fbdev_dec_ref(fbdev);
		fbdev = nullptr;
		{
			std::lock_guard<std::mutex> lock(s_state_mutex);
			s_fb_vram.clear();
			s_fb_vram.shrink_to_fit();
		}
		return true;
	}
}

@implementation RV64Runner

static NSString *DocumentsDirectory(void)
{
	NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	return dirs.count > 0 ? dirs[0] : nil;
}

static BOOL IsVMRunning(void)
{
	std::lock_guard<std::mutex> lock(s_state_mutex);
	return s_machine != nullptr;
}

static BOOL ValidImageName(NSString *name)
{
	return name.length > 0 && ![name containsString:@"/"] && ![name hasPrefix:@"."];
}

static std::string DocumentsPathFor(NSString *name)
{
	NSString *dir = DocumentsDirectory();
	if (!dir || !ValidImageName(name)) {
		return {};
	}
	return UTF8FromNSString([dir stringByAppendingPathComponent:name]);
}

+ (BOOL)createDiskImageNamed:(NSString *)name
                   sizeBytes:(unsigned long long)sizeBytes
                       error:(NSString * _Nullable * _Nullable)errorOut
{
	if (IsVMRunning()) {
		return SetErrorString(errorOut, @"Stop the VM before changing disk images");
	}
	std::string path = DocumentsPathFor(name);
	if (path.empty() || sizeBytes == 0) {
		return SetErrorString(errorOut, @"Invalid image name or size");
	}
	if (!CreateSparseImage(path, (uint64_t)sizeBytes)) {
		return SetErrorString(errorOut, @"Could not create image (name in use or no space)");
	}
	return YES;
}

+ (BOOL)expandDiskImageNamed:(NSString *)name
                 toSizeBytes:(unsigned long long)sizeBytes
                       error:(NSString * _Nullable * _Nullable)errorOut
{
	if (IsVMRunning()) {
		return SetErrorString(errorOut, @"Stop the VM before changing disk images");
	}
	std::string path = DocumentsPathFor(name);
	if (path.empty()) {
		return SetErrorString(errorOut, @"Invalid image name");
	}
	if (!ExpandSparseImage(path, (uint64_t)sizeBytes)) {
		return SetErrorString(errorOut, @"Image can only grow, and the size must be larger than the current one");
	}
	return YES;
}

+ (BOOL)sparsifyDiskImageNamed:(NSString *)name
                         error:(NSString * _Nullable * _Nullable)errorOut
{
	if (IsVMRunning()) {
		return SetErrorString(errorOut, @"Stop the VM before changing disk images");
	}
	std::string path = DocumentsPathFor(name);
	if (path.empty() || !SparsifyImage(path)) {
		return SetErrorString(errorOut, @"Could not make image sparse");
	}
	return YES;
}

+ (BOOL)importDiskImageFromPath:(NSString *)sourcePath
                         asName:(NSString *)name
                          error:(NSString * _Nullable * _Nullable)errorOut
{
	if (IsVMRunning()) {
		return SetErrorString(errorOut, @"Stop the VM before importing disk images");
	}
	std::string src = UTF8FromNSString(sourcePath);
	std::string dst = DocumentsPathFor(name);
	if (src.empty() || dst.empty()) {
		return SetErrorString(errorOut, @"Invalid import path");
	}
	// Copy with holes preserved, so imported images stay sparse on disk.
	uint64_t size = 0;
	if (!SparseCopyFile(src, dst, &size)) {
		unlink(dst.c_str());
		return SetErrorString(errorOut, @"Import failed");
	}
	return YES;
}

+ (BOOL)importFirmwareFromPath:(NSString *)sourcePath
                          name:(NSString * _Nullable * _Nullable)nameOut
                         error:(NSString * _Nullable * _Nullable)errorOut
{
	NSString *docs = DocumentsDirectory();
	if (!docs) {
		return SetErrorString(errorOut, @"Documents folder unavailable");
	}
	NSString *dirPath = [docs stringByAppendingPathComponent:@"firmware"];
	[[NSFileManager defaultManager] createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:nil];
	NSString *name = [sourcePath lastPathComponent];
	std::string src = UTF8FromNSString(sourcePath);
	std::string dst = UTF8FromNSString([dirPath stringByAppendingPathComponent:name]);
	uint64_t size = 0;
	if (src.empty() || dst.empty() || !SparseCopyFile(src, dst, &size)) {
		return SetErrorString(errorOut, @"Firmware import failed");
	}
	if (nameOut) {
		*nameOut = name;
	}
	return YES;
}

+ (void)startLinux
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		EnsureRestartSemaphore();
		EnsureSnapshotPrimitives();
		EnsureNetworkPrimitives();
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			for (;;) {
				(void)RunLinuxOnce();
				if (s_restart_requested.exchange(false)) {
					dispatch_semaphore_wait(s_restart_sema, DISPATCH_TIME_NOW);
					continue;
				}
				dispatch_semaphore_wait(s_restart_sema, DISPATCH_TIME_FOREVER);
				(void)s_restart_requested.exchange(false);
			}
		});
	});
}

+ (uint32_t)framebufferSeq
{
	return s_fb_seq.load(std::memory_order_relaxed);
}

+ (void)framebufferMetaWidth:(uint32_t * _Nullable)widthOut
                      height:(uint32_t * _Nullable)heightOut
                      stride:(uint32_t * _Nullable)strideOut
                      format:(uint32_t * _Nullable)formatOut
                      offset:(uint32_t * _Nullable)offsetOut
{
	if (widthOut) {
		*widthOut = s_fb_width.load(std::memory_order_relaxed);
	}
	if (heightOut) {
		*heightOut = s_fb_height.load(std::memory_order_relaxed);
	}
	if (strideOut) {
		*strideOut = s_fb_stride.load(std::memory_order_relaxed);
	}
	if (formatOut) {
		*formatOut = s_fb_format.load(std::memory_order_relaxed);
	}
	if (offsetOut) {
		*offsetOut = s_fb_offset.load(std::memory_order_relaxed);
	}
}
+ (void)setVirtioFSDebugToUARTEnabled:(BOOL)enabled
{
	s_vfs_debug_to_uart.store(enabled);
}


+ (NSArray<NSString *> *)virtioFSDebugLines
{
	std::lock_guard<std::mutex> lock(s_vfs_debug_mu);
	NSMutableArray<NSString *> *out = [[NSMutableArray alloc] initWithCapacity:(NSUInteger)s_vfs_debug_lines.size()];
	for (const std::string& line : s_vfs_debug_lines) {
		NSString *s = NSStringFromUTF8String(line);
		if (s.length > 0) {
			[out addObject:s];
		}
	}
	return out;
}

+ (void)clearVirtioFSDebug
{
	std::lock_guard<std::mutex> lock(s_vfs_debug_mu);
	s_vfs_debug_lines.clear();
	s_vfs_debug_bytes = 0;
}

+ (void)requestRestart
{
	EnsureRestartSemaphore();
	bool already = s_restart_requested.exchange(true);
	if (!already) {
		dispatch_semaphore_signal(s_restart_sema);
	}
	rvvm_machine_t* machine = nullptr;
	{
		std::lock_guard<std::mutex> lock(s_state_mutex);
		machine = s_machine;
	}
	if (machine) {
		rvvm_pause_machine(machine);
	}
}

+ (BOOL)isRunning
{
	return IsVMRunning();
}

+ (void)reinitNetwork
{
	std::lock_guard<std::mutex> lock(s_state_mutex);
	if (s_tap) {
		tap_reinit(s_tap);
	}
}

+ (BOOL)saveSnapshot:(NSString * _Nullable * _Nullable)errorOut
{
	EnsureSnapshotPrimitives();
	rvvm_machine_t* machine = nullptr;
	bool running = false;
	{
		std::lock_guard<std::mutex> lock(s_state_mutex);
		machine = s_machine;
		running = machine ? rvvm_machine_running(machine) : false;
	}
	if (!machine || !running) {
		if (errorOut) {
			*errorOut = @"VM is not running";
		}
		return NO;
	}
	int expected = 0;
	if (!s_snapshot_op.compare_exchange_strong(expected, 1)) {
		if (errorOut) {
			*errorOut = @"Snapshot operation already in progress";
		}
		return NO;
	}
	while (dispatch_semaphore_wait(s_snapshot_done_sema, DISPATCH_TIME_NOW) == 0) {
	}
	if (!rvvm_pause_machine(machine)) {
		s_snapshot_op.store(0);
		if (errorOut) {
			*errorOut = @"Failed to pause VM";
		}
		return NO;
	}
	int64_t timeoutNsec = (int64_t)(300 * NSEC_PER_SEC);
	long waitRes = dispatch_semaphore_wait(s_snapshot_done_sema, dispatch_time(DISPATCH_TIME_NOW, timeoutNsec));
	if (waitRes != 0) {
		s_snapshot_op.store(0);
		rvvm_start_machine(machine);
		if (errorOut) {
			*errorOut = @"Snapshot save timed out";
		}
		return NO;
	}
	bool ok = false;
	std::string msg;
	{
		std::lock_guard<std::mutex> lock(s_snapshot_result_mu);
		ok = s_snapshot_result_ok;
		msg = s_snapshot_result_msg;
	}
	if (!ok) {
		if (errorOut) {
			NSString *m = NSStringFromUTF8String(msg);
			*errorOut = (m.length > 0) ? m : @"Snapshot save failed";
		}
		return NO;
	}
	return YES;
}

+ (BOOL)loadSnapshot:(NSString * _Nullable * _Nullable)errorOut
{
	EnsureSnapshotPrimitives();
	rvvm_machine_t* machine = nullptr;
	bool running = false;
	{
		std::lock_guard<std::mutex> lock(s_state_mutex);
		machine = s_machine;
		running = machine ? rvvm_machine_running(machine) : false;
	}
	if (!machine || !running) {
		if (errorOut) {
			*errorOut = @"VM is not running";
		}
		return NO;
	}
	int expected = 0;
	if (!s_snapshot_op.compare_exchange_strong(expected, 2)) {
		if (errorOut) {
			*errorOut = @"Snapshot operation already in progress";
		}
		return NO;
	}
	while (dispatch_semaphore_wait(s_snapshot_done_sema, DISPATCH_TIME_NOW) == 0) {
	}
	if (!rvvm_pause_machine(machine)) {
		s_snapshot_op.store(0);
		if (errorOut) {
			*errorOut = @"Failed to pause VM";
		}
		return NO;
	}
	int64_t timeoutNsec = (int64_t)(300 * NSEC_PER_SEC);
	long waitRes = dispatch_semaphore_wait(s_snapshot_done_sema, dispatch_time(DISPATCH_TIME_NOW, timeoutNsec));
	if (waitRes != 0) {
		s_snapshot_op.store(0);
		rvvm_start_machine(machine);
		if (errorOut) {
			*errorOut = @"Snapshot load timed out";
		}
		return NO;
	}
	bool ok = false;
	std::string msg;
	{
		std::lock_guard<std::mutex> lock(s_snapshot_result_mu);
		ok = s_snapshot_result_ok;
		msg = s_snapshot_result_msg;
	}
	if (!ok) {
		if (errorOut) {
			NSString *m = NSStringFromUTF8String(msg);
			*errorOut = (m.length > 0) ? m : @"Snapshot load failed";
		}
		return NO;
	}
	return YES;
}

+ (BOOL)reinitNetwork:(NSString * _Nullable * _Nullable)errorOut
{
	EnsureNetworkPrimitives();
	rvvm_machine_t* machine = nullptr;
	bool running = false;
	{
		std::lock_guard<std::mutex> lock(s_state_mutex);
		machine = s_machine;
		running = machine ? rvvm_machine_running(machine) : false;
	}
	if (!machine || !running) {
		if (errorOut) {
			*errorOut = @"VM is not running";
		}
		return NO;
	}
	if (s_snapshot_op.load() != 0) {
		if (errorOut) {
			*errorOut = @"Another VM operation is in progress";
		}
		return NO;
	}
	int expected = 0;
	if (!s_network_op.compare_exchange_strong(expected, 1)) {
		if (errorOut) {
			*errorOut = @"Network operation already in progress";
		}
		return NO;
	}
	while (dispatch_semaphore_wait(s_network_done_sema, DISPATCH_TIME_NOW) == 0) {
	}
	if (!rvvm_pause_machine(machine)) {
		s_network_op.store(0);
		if (errorOut) {
			*errorOut = @"Failed to pause VM";
		}
		return NO;
	}
	int64_t timeoutNsec = (int64_t)(60 * NSEC_PER_SEC);
	long waitRes = dispatch_semaphore_wait(s_network_done_sema, dispatch_time(DISPATCH_TIME_NOW, timeoutNsec));
	if (waitRes != 0) {
		s_network_op.store(0);
		rvvm_start_machine(machine);
		if (errorOut) {
			*errorOut = @"Network reinit timed out";
		}
		return NO;
	}
	bool ok = false;
	std::string msg;
	{
		std::lock_guard<std::mutex> lock(s_network_result_mu);
		ok = s_network_result_ok;
		msg = s_network_result_msg;
	}
	if (!ok) {
		if (errorOut) {
			NSString *m = NSStringFromUTF8String(msg);
			*errorOut = (m.length > 0) ? m : @"Network reinit failed";
		}
		return NO;
	}
	return YES;
}

+ (void)sendConsoleBytes:(NSData *)data
{
	if (!data || data.length == 0) {
		return;
	}
	std::lock_guard<std::mutex> lock(s_state_mutex);
	if (!s_chardev || !s_chardev->data) {
		return;
	}
	auto* state = (UIKitChardevState *)s_chardev->data;
	{
		std::lock_guard<std::mutex> rxLock(state->mu);
		const auto* b = (const uint8_t *)data.bytes;
		for (size_t i = 0; i < (size_t)data.length; i++) {
			uint8_t c = b[i];
			if (c == '\r') {
				c = '\n';
			}
			state->rx.push_back(c);
		}
	}
	chardev_notify(s_chardev, UIKitChardevPoll(s_chardev));
}

+ (void)sendConsoleText:(NSString *)text
{
	if (!text || text.length == 0) {
		return;
	}
	std::string bytes = UTF8FromNSString(text);
	if (bytes.empty()) {
		return;
	}
	std::lock_guard<std::mutex> lock(s_state_mutex);
	if (!s_chardev || !s_chardev->data) {
		return;
	}
	auto* state = (UIKitChardevState *)s_chardev->data;
	{
		std::lock_guard<std::mutex> rxLock(state->mu);
		for (char c : bytes) {
			if (c == '\r') {
				c = '\n';
			}
			state->rx.push_back((uint8_t)c);
		}
		state->rx.push_back((uint8_t)'\n');
	}
	chardev_notify(s_chardev, UIKitChardevPoll(s_chardev));
}

+ (BOOL)copyFramebufferBGRA:(NSMutableData *)outData
                    width:(NSUInteger * _Nullable)widthOut
                   height:(NSUInteger * _Nullable)heightOut
              bytesPerRow:(NSUInteger * _Nullable)bytesPerRowOut
{
	if (!outData) {
		return NO;
	}

	rvvm_fbdev_t* fbdev = nullptr;
	{
		std::lock_guard<std::mutex> lock(s_state_mutex);
		fbdev = s_fbdev;
		if (fbdev) {
			rvvm_fbdev_inc_ref(fbdev);
		}
	}
	if (!fbdev) {
		return NO;
	}

	rvvm_fb_t fb = {};
	if (!rvvm_fbdev_get_scanout(fbdev, &fb) || !fb.buffer || fb.width == 0 || fb.height == 0 || fb.stride == 0) {
		(void)rvvm_fbdev_dec_ref(fbdev);
		return NO;
	}
	if (fb.format != RVVM_RGB_XRGB8888) {
		(void)rvvm_fbdev_dec_ref(fbdev);
		return NO;
	}

	const size_t total = (size_t)fb.stride * (size_t)fb.height;
	[outData setLength:total];
	uint8_t* dst = (uint8_t *)outData.mutableBytes;
	const uint8_t* src = (const uint8_t *)fb.buffer;
	memcpy(dst, src, total);

	if (widthOut) {
		*widthOut = (NSUInteger)fb.width;
	}
	if (heightOut) {
		*heightOut = (NSUInteger)fb.height;
	}
	if (bytesPerRowOut) {
		*bytesPerRowOut = (NSUInteger)fb.stride;
	}
	(void)rvvm_fbdev_dec_ref(fbdev);
	return YES;
}

+ (void)sendVirtioText:(NSString *)text
{
	if (!text || text.length == 0) {
		return;
	}
	std::string bytes = UTF8FromNSString(text);
	if (bytes.empty()) {
		return;
	}
	hid_keyboard_t* kb = nullptr;
	{
		std::lock_guard<std::mutex> lock(s_state_mutex);
		kb = s_uart_keyboard_virtio;
	}
	if (!kb) {
		return;
	}
	for (uint8_t c : bytes) {
		hid_key_t key = HID_KEY_NONE;
		bool shift = false;
		bool ctrl = false;
		if (!MapAsciiToHidKey(c, &key, &shift, &ctrl)) {
			continue;
		}
		InjectHidKeyVirtio(kb, key, shift, ctrl, false);
	}
}

+ (void)sendVirtioText:(NSString *)text ctrl:(BOOL)ctrl alt:(BOOL)alt
{
	if (!text || text.length == 0) {
		return;
	}
	std::string bytes = UTF8FromNSString(text);
	if (bytes.empty()) {
		return;
	}
	hid_keyboard_t* kb = nullptr;
	{
		std::lock_guard<std::mutex> lock(s_state_mutex);
		kb = s_uart_keyboard_virtio;
	}
	if (!kb) {
		return;
	}
	for (uint8_t c : bytes) {
		hid_key_t key = HID_KEY_NONE;
		bool shift = false;
		bool ctrlFromAscii = false;
		if (!MapAsciiToHidKey(c, &key, &shift, &ctrlFromAscii)) {
			continue;
		}
		InjectHidKeyVirtio(kb, key, shift, ctrlFromAscii || ctrl, alt);
	}
}

+ (void)sendVirtioKey:(uint8_t)hidKey
               shift:(BOOL)shift
                ctrl:(BOOL)ctrl
                 alt:(BOOL)alt
{
	hid_keyboard_t* kb = nullptr;
	{
		std::lock_guard<std::mutex> lock(s_state_mutex);
		kb = s_uart_keyboard_virtio;
	}
	if (!kb || hidKey == 0) {
		return;
	}

	InjectHidKeyVirtio(kb, (hid_key_t)hidKey, shift, ctrl, alt);
}

+ (void)sendVirtioMouseDeltaX:(int32_t)dx deltaY:(int32_t)dy
{
	hid_mouse_t* mouse = nullptr;
	{
		std::lock_guard<std::mutex> lock(s_state_mutex);
		mouse = s_mouse_virtio;
	}
	if (!mouse) {
		return;
	}
	hid_mouse_move_virtio(mouse, dx, dy);
}

+ (void)setVirtioMouseResolutionWidth:(uint32_t)width height:(uint32_t)height
{
	if (width == 0 || height == 0) {
		return;
	}
	if (s_mouse_abs_width.load(std::memory_order_relaxed) == width &&
	    s_mouse_abs_height.load(std::memory_order_relaxed) == height) {
		return;
	}
	hid_mouse_t* mouse = nullptr;
	{
		std::lock_guard<std::mutex> lock(s_state_mutex);
		mouse = s_mouse_virtio;
	}
	if (!mouse) {
		return;
	}
	hid_mouse_resolution_virtio(mouse, width, height);
	s_mouse_abs_width.store(width, std::memory_order_relaxed);
	s_mouse_abs_height.store(height, std::memory_order_relaxed);
}

+ (void)sendVirtioMouseAbsX:(int32_t)x absY:(int32_t)y
{
	hid_mouse_t* mouse = nullptr;
	{
		std::lock_guard<std::mutex> lock(s_state_mutex);
		mouse = s_mouse_virtio;
	}
	if (!mouse) {
		return;
	}
	hid_mouse_place_virtio(mouse, x, y);
}

+ (void)sendVirtioMouseButtons:(uint8_t)btnMask down:(BOOL)down
{
	hid_mouse_t* mouse = nullptr;
	{
		std::lock_guard<std::mutex> lock(s_state_mutex);
		mouse = s_mouse_virtio;
	}
	if (!mouse || btnMask == 0) {
		return;
	}
	if (down) {
		hid_mouse_press_virtio(mouse, (hid_btns_t)btnMask);
	} else {
		hid_mouse_release_virtio(mouse, (hid_btns_t)btnMask);
	}
}

+ (void)sendVirtioMouseScroll:(int32_t)offset
{
	hid_mouse_t* mouse = nullptr;
	{
		std::lock_guard<std::mutex> lock(s_state_mutex);
		mouse = s_mouse_virtio;
	}
	if (!mouse) {
		return;
	}
	hid_mouse_scroll_virtio(mouse, offset);
}

@end
