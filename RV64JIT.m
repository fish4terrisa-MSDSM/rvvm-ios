#import "RV64JIT.h"

#import <UIKit/UIKit.h>
#import <sys/types.h>
#import <unistd.h>

// Not every SDK exposes this in a public header; the symbol itself is in libsystem_kernel.
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

static NSString *const kRVVMDefaultsAutoJIT = @"rvvm.autoJIT";
static const uint32_t kCSDebugged = 0x10000000; // CS_DEBUGGED
static const unsigned int kCSOpsStatus = 0;     // CS_OPS_STATUS
static BOOL s_requestedThisLaunch = NO;

@implementation RV64JIT

+ (BOOL)debuggerAttached
{
	uint32_t flags = 0;
	if (csops(getpid(), kCSOpsStatus, &flags, sizeof(flags)) != 0) {
		return NO;
	}
	return (flags & kCSDebugged) != 0;
}

+ (void)requestJITFromStikDebugIfNeeded
{
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	BOOL autoJIT = [d objectForKey:kRVVMDefaultsAutoJIT] ? [d boolForKey:kRVVMDefaultsAutoJIT] : YES;
	if (!autoJIT || s_requestedThisLaunch) {
		return;
	}
	// Never disable JIT here. Some attach methods hide the debugger flag while JIT stays active,
	// so a missing flag only means "not detected", and the request is still sent once per launch.
	if ([self debuggerAttached]) {
		s_requestedThisLaunch = YES;
		return;
	}
	NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
	if (bundleID.length == 0) {
		return;
	}
	NSURLComponents *c = [NSURLComponents new];
	c.scheme = @"stikdebug";
	c.host = @"enable-jit";
	c.queryItems = @[
		[NSURLQueryItem queryItemWithName:@"bundle-id" value:bundleID],
		[NSURLQueryItem queryItemWithName:@"pid" value:[NSString stringWithFormat:@"%d", getpid()]],
	];
	NSURL *url = c.URL;
	if (!url) {
		return;
	}
	s_requestedThisLaunch = YES;
	dispatch_async(dispatch_get_main_queue(), ^{
		[UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
	});
}

@end
