#import "RV64AppDelegate.h"
#import "RV64RootViewController.h"
#import "RV64Runner.h"
#import "RV64BackgroundKeeper.h"

#import <dispatch/dispatch.h>

static NSString *const kRVVMDefaultsBackgroundEnabled = @"rvvm.backgroundEnabled";
static NSString *const kRVVMDefaultsBackgroundMode = @"rvvm.backgroundMode";

@implementation RV64AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];

	RV64RootViewController *terminalRoot = [[RV64RootViewController alloc] init];
	UINavigationController *terminalNav = [[UINavigationController alloc] initWithRootViewController:terminalRoot];
	terminalNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Terminal" image:nil tag:0];

	RV64FramebufferViewController *fbRoot = [[RV64FramebufferViewController alloc] init];
	UINavigationController *fbNav = [[UINavigationController alloc] initWithRootViewController:fbRoot];
	fbNav.navigationBarHidden = YES;
	fbNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Framebuffer" image:nil tag:1];

	UITabBarController *tabs = [[UITabBarController alloc] init];
	tabs.viewControllers = @[terminalNav, fbNav];
	tabs.tabBar.hidden = YES;
	self.window.rootViewController = tabs;
	[self.window makeKeyAndVisible];

	// Configure the background keep-alive from stored settings (item 14)
	NSString *mode = [NSUserDefaults.standardUserDefaults stringForKey:kRVVMDefaultsBackgroundMode] ?: @"none";
	RV64BackgroundStrategy strategy = RV64BackgroundStrategyNone;
	if ([mode isEqualToString:@"audio"]) strategy = RV64BackgroundStrategyAudio;
	else if ([mode isEqualToString:@"task"]) strategy = RV64BackgroundStrategyTask;
	else if ([mode isEqualToString:@"location"]) strategy = RV64BackgroundStrategyLocation;
	else if ([mode isEqualToString:@"combo"]) strategy = RV64BackgroundStrategyCombo;
	[RV64BackgroundKeeper shared].strategy = strategy;
	if ([NSUserDefaults.standardUserDefaults boolForKey:kRVVMDefaultsBackgroundEnabled]) {
		[[RV64BackgroundKeeper shared] start];
	}
	return YES;
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options
{
	(void)app;
	(void)options;
	// rvvm:// callback scheme (used by JIT enablers such as StikDebug).
	// The presence of the callback already means an enabler is active; JIT
	// request happens automatically on the next (re)start of the VM.
	if ([url.scheme.lowercaseString isEqualToString:@"rvvm"]) {
		[NSUserDefaults.standardUserDefaults setObject:url.absoluteString forKey:@"rvvm.lastCallbackURL"];
		[NSUserDefaults.standardUserDefaults synchronize];
	}
	return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
	(void)application;
	if ([NSUserDefaults.standardUserDefaults boolForKey:kRVVMDefaultsBackgroundEnabled]) {
		[[RV64BackgroundKeeper shared] start];
	}
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
	(void)application;
	// keep-alive stays managed by the Background settings page
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
	(void)application;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		[RV64Runner reinitNetwork];
	});
}

@end
