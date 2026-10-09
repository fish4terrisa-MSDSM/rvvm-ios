#import "RV64AppDelegate.h"
#import "RV64RootViewController.h"
#import "RV64Runner.h"

#import <AVFoundation/AVFoundation.h>
#import <dispatch/dispatch.h>

static NSString *const kRVVMDefaultsBackgroundMode = @"rvvm.backgroundMode";

// Background modes (rvvm.backgroundMode).
typedef NS_ENUM(NSInteger, RVVMBackgroundMode) {
	RVVMBackgroundModeOff = 0,
	RVVMBackgroundModeSilentAudio = 1,
	RVVMBackgroundModeBackgroundTask = 2,
};

// One second of 8 kHz mono 16-bit silence as an in-memory WAV file.
static NSData *SilentWAVData(void)
{
	const uint32_t sampleRate = 8000;
	const uint16_t channels = 1;
	const uint16_t bitsPerSample = 16;
	const uint32_t dataBytes = sampleRate * channels * (bitsPerSample / 8);
	const uint32_t byteRate = sampleRate * channels * (bitsPerSample / 8);
	const uint16_t blockAlign = channels * (bitsPerSample / 8);

	NSMutableData *d = [NSMutableData dataWithCapacity:44 + dataBytes];
	void (^u32)(uint32_t) = ^(uint32_t v) {
		uint8_t b[4] = {(uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24)};
		[d appendBytes:b length:4];
	};
	void (^u16)(uint16_t) = ^(uint16_t v) {
		uint8_t b[2] = {(uint8_t)v, (uint8_t)(v >> 8)};
		[d appendBytes:b length:2];
	};
	[d appendBytes:"RIFF" length:4];
	u32(36 + dataBytes);
	[d appendBytes:"WAVE" length:4];
	[d appendBytes:"fmt " length:4];
	u32(16);
	u16(1); // PCM
	u16(channels);
	u32(sampleRate);
	u32(byteRate);
	u16(blockAlign);
	u16(bitsPerSample);
	[d appendBytes:"data" length:4];
	u32(dataBytes);
	[d increaseLengthBy:dataBytes]; // zero-filled = silence
	return d;
}

@interface RV64AppDelegate ()
@property (nonatomic, strong) AVAudioPlayer *silentPlayer;
@property (nonatomic) UIBackgroundTaskIdentifier backgroundTask;
@end

@implementation RV64AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	self.backgroundTask = UIBackgroundTaskInvalid;

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

	[[NSNotificationCenter defaultCenter] addObserver:self
	                                         selector:@selector(audioSessionInterrupted:)
	                                             name:AVAudioSessionInterruptionNotification
	                                           object:nil];
	return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
	(void)application;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		[RV64Runner reinitNetwork];
	});
}

#pragma mark - Background keep-alive

- (void)applicationDidEnterBackground:(UIApplication *)application
{
	if (![RV64Runner isRunning]) {
		return;
	}
	NSInteger mode = [NSUserDefaults.standardUserDefaults integerForKey:kRVVMDefaultsBackgroundMode];
	if (mode == RVVMBackgroundModeSilentAudio) {
		[self startSilentAudio];
	} else if (mode == RVVMBackgroundModeBackgroundTask) {
		[self beginBackgroundTaskWithApplication:application];
	}
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
	[self stopSilentAudio];
	[self endBackgroundTaskWithApplication:application];
}

- (void)startSilentAudio
{
	if (self.silentPlayer.isPlaying) {
		return;
	}
	NSError *err = nil;
	AVAudioSession *session = AVAudioSession.sharedInstance;
	// Playback category keeps audio alive in the background. MixWithOthers avoids stopping the user's music.
	if (![session setCategory:AVAudioSessionCategoryPlayback
	              withOptions:AVAudioSessionCategoryOptionMixWithOthers
	                    error:&err]) {
		NSLog(@"rvvm: audio category failed: %@", err);
		return;
	}
	if (![session setActive:YES error:&err]) {
		NSLog(@"rvvm: audio session activate failed: %@", err);
		return;
	}
	if (!self.silentPlayer) {
		self.silentPlayer = [[AVAudioPlayer alloc] initWithData:SilentWAVData() error:&err];
		if (!self.silentPlayer) {
			NSLog(@"rvvm: silent player failed: %@", err);
			return;
		}
		self.silentPlayer.numberOfLoops = -1;
		self.silentPlayer.volume = 0.0f;
		[self.silentPlayer prepareToPlay];
	}
	[self.silentPlayer play];
}

- (void)stopSilentAudio
{
	[self.silentPlayer stop];
	self.silentPlayer = nil;
	[AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
}

- (void)audioSessionInterrupted:(NSNotification *)note
{
	NSUInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
	if (type == AVAudioSessionInterruptionTypeEnded &&
	    [NSUserDefaults.standardUserDefaults integerForKey:kRVVMDefaultsBackgroundMode] == RVVMBackgroundModeSilentAudio &&
	    [RV64Runner isRunning] &&
	    UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
		// Another app or a call stopped the silent loop; resume it so the VM keeps running in the background.
		[self startSilentAudio];
	}
}

- (void)beginBackgroundTaskWithApplication:(UIApplication *)application
{
	if (self.backgroundTask != UIBackgroundTaskInvalid) {
		return;
	}
	// iOS grants roughly 30 seconds; the task is renewed by backgrounding again.
	self.backgroundTask = [application beginBackgroundTaskWithName:@"rvvm-keepalive" expirationHandler:^{
		[self endBackgroundTaskWithApplication:application];
	}];
}

- (void)endBackgroundTaskWithApplication:(UIApplication *)application
{
	if (self.backgroundTask == UIBackgroundTaskInvalid) {
		return;
	}
	[application endBackgroundTask:self.backgroundTask];
	self.backgroundTask = UIBackgroundTaskInvalid;
}

@end
