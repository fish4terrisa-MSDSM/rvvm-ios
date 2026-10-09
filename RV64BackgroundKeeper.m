#import "RV64BackgroundKeeper.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>

@interface RV64BackgroundKeeper () <CLLocationManagerDelegate>
@property (nonatomic, strong) AVAudioPlayer *silentPlayer;
@property (nonatomic, strong) CLLocationManager *locationManager;
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTask;
@property (nonatomic, strong) NSTimer *heartbeat;
@property (nonatomic, assign) BOOL active;
@end

@implementation RV64BackgroundKeeper

+ (instancetype)shared
{
	static RV64BackgroundKeeper *keeper;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		keeper = [[RV64BackgroundKeeper alloc] init];
		keeper.bgTask = UIBackgroundTaskInvalid;
		keeper.strategy = RV64BackgroundStrategyNone;
	});
	return keeper;
}

#pragma mark - Silent audio (UIBackgroundModes: audio)

- (NSString *)silentWavPath
{
	NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"rvvm-silence.wav"];
	if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
		// Generate 30 seconds of 8 kHz mono 8-bit silence at runtime
		const uint32_t sampleRate = 8000;
		const uint32_t seconds = 30;
		const uint32_t dataLen = sampleRate * seconds;
		NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataLen];
		uint32_t chunk;
		uint16_t u16;
		uint32_t u32;
		const char *riff = "RIFF"; [wav appendBytes:riff length:4];
		u32 = CFSwapInt32HostToLittle(36 + dataLen); [wav appendBytes:&u32 length:4];
		const char *wave = "WAVEfmt "; [wav appendBytes:wave length:8];
		u32 = CFSwapInt32HostToLittle(16); [wav appendBytes:&u32 length:4]; // fmt size
		u16 = CFSwapInt16HostToLittle(1); [wav appendBytes:&u16 length:2];  // PCM
		u16 = CFSwapInt16HostToLittle(1); [wav appendBytes:&u16 length:2];  // mono
		u32 = CFSwapInt32HostToLittle(sampleRate); [wav appendBytes:&u32 length:4];
		u32 = CFSwapInt32HostToLittle(sampleRate); [wav appendBytes:&u32 length:4]; // byte rate
		u16 = CFSwapInt16HostToLittle(1); [wav appendBytes:&u16 length:2];  // block align
		u16 = CFSwapInt16HostToLittle(8); [wav appendBytes:&u16 length:2];  // bits
		const char *data = "data"; [wav appendBytes:data length:4];
		u32 = CFSwapInt32HostToLittle(dataLen); [wav appendBytes:&u32 length:4];
		const char zeros[4096] = {0};
		uint32_t left = dataLen;
		while (left > 0) {
			uint32_t chunk2 = left > sizeof(zeros) ? (uint32_t)sizeof(zeros) : left;
			[wav appendBytes:zeros length:chunk2];
			left -= chunk2;
		}
		[wav writeToFile:path atomically:YES];
	}
	return path;
}

- (BOOL)startSilentAudio
{
	NSError *err = nil;
	AVAudioSession *session = AVAudioSession.sharedInstance;
	// Playback + mixWithOthers keeps the session alive without audible output
	if (![session setCategory:AVAudioSessionCategoryPlayback
	                   options:AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionDuckOthers
	                     error:&err]) {
		return NO;
	}
	if (![session setActive:YES error:&err]) {
		return NO;
	}
	NSString *path = [self silentWavPath];
	self.silentPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&err];
	if (!self.silentPlayer) {
		return NO;
	}
	self.silentPlayer.numberOfLoops = -1; // loop forever
	self.silentPlayer.volume = 0.01;
	return [self.silentPlayer play];
}

- (void)stopSilentAudio
{
	[self.silentPlayer stop];
	self.silentPlayer = nil;
	[AVAudioSession.sharedInstance setActive:NO
	                              options:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
	                                error:nil];
}

#pragma mark - Background task renewal

- (void)beginBgTask
{
	if (self.bgTask != UIBackgroundTaskInvalid) {
		return;
	}
	self.bgTask = [UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{
		// Renew for another grace period; iOS will eventually refuse
		UIBackgroundTaskIdentifier old = self.bgTask;
		self.bgTask = UIBackgroundTaskInvalid;
		if (old != UIBackgroundTaskInvalid) {
			[UIApplication.sharedApplication endBackgroundTask:old];
		}
		if (self.active && (self.strategy == RV64BackgroundStrategyTask || self.strategy == RV64BackgroundStrategyCombo)) {
			[self beginBgTask];
		}
		if (self.onExpiry) {
			self.onExpiry();
		}
	}];
}

- (void)endBgTask
{
	if (self.bgTask != UIBackgroundTaskInvalid) {
		[UIApplication.sharedApplication endBackgroundTask:self.bgTask];
		self.bgTask = UIBackgroundTaskInvalid;
	}
}

#pragma mark - Location (UIBackgroundModes: location)

- (void)startLocation
{
	if (!self.locationManager) {
		self.locationManager = [[CLLocationManager alloc] init];
		self.locationManager.delegate = self;
		self.locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers;
		self.locationManager.distanceFilter = 3000;
	}
	[self.locationManager requestAlwaysAuthorization];
	self.locationManager.allowsBackgroundLocationUpdates = YES;
	self.locationManager.pausesLocationUpdatesAutomatically = NO;
	if ([CLLocationManager significantLocationChangeMonitoringAvailable]) {
		[self.locationManager startMonitoringSignificantLocationChanges];
	}
	[self.locationManager startUpdatingLocation];
}

- (void)stopLocation
{
	[self.locationManager stopUpdatingLocation];
	[self.locationManager stopMonitoringSignificantLocationChanges];
	self.locationManager.allowsBackgroundLocationUpdates = NO;
}

- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status
{
	(void)manager;
	if (status == kCLAuthorizationStatusAuthorizedAlways || status == kCLAuthorizationStatusAuthorizedWhenInUse) {
		// keep monitoring
	}
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations
{
	(void)manager;
	(void)locations;
	// Heartbeat only: presence of updates keeps the process scheduled
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
	(void)manager;
	(void)error;
}

#pragma mark - Heartbeat timer

- (void)startHeartbeat
{
	[self stopHeartbeat];
	self.heartbeat = [NSTimer scheduledTimerWithTimeInterval:60.0
	                                                  target:self
	                                                selector:@selector(heartbeatFired)
	                                                userInfo:nil
	                                                 repeats:YES];
}

- (void)stopHeartbeat
{
	[self.heartbeat invalidate];
	self.heartbeat = nil;
}

- (void)heartbeatFired
{
	// Refresh the audio session & bg task; cheap and keeps the process active
	if (self.strategy == RV64BackgroundStrategyAudio || self.strategy == RV64BackgroundStrategyCombo) {
		if (!self.silentPlayer.isPlaying) {
			[self startSilentAudio];
		}
	}
	if (self.strategy == RV64BackgroundStrategyTask || self.strategy == RV64BackgroundStrategyCombo) {
		if (self.bgTask == UIBackgroundTaskInvalid) {
			[self beginBgTask];
		}
	}
}

#pragma mark - Public control

- (void)setStrategy:(RV64BackgroundStrategy)strategy
{
	_strategy = strategy;
	if (self.active) {
		[self stop];
		[self start];
	}
}

- (void)start
{
	self.active = YES;
	switch (self.strategy) {
		case RV64BackgroundStrategyNone:
			break;
		case RV64BackgroundStrategyAudio:
			[self startSilentAudio];
			break;
		case RV64BackgroundStrategyTask:
			[self beginBgTask];
			break;
		case RV64BackgroundStrategyLocation:
			[self startLocation];
			break;
		case RV64BackgroundStrategyCombo:
			[self startSilentAudio];
			[self beginBgTask];
			[self startLocation];
			break;
	}
	if (self.strategy != RV64BackgroundStrategyNone) {
		[self startHeartbeat];
	}
}

- (void)stop
{
	self.active = NO;
	[self stopSilentAudio];
	[self endBgTask];
	[self stopLocation];
	[self stopHeartbeat];
}

- (NSString *)statusText
{
	switch (self.strategy) {
		case RV64BackgroundStrategyNone:
			return @"Off (system default)";
		case RV64BackgroundStrategyAudio:
			return self.active ? @"Silent audio loop (active)" : @"Silent audio loop";
		case RV64BackgroundStrategyTask:
			return self.active ? @"Background task renewal (active)" : @"Background task renewal";
		case RV64BackgroundStrategyLocation:
			return self.active ? @"Location heartbeat (active)" : @"Location heartbeat";
		case RV64BackgroundStrategyCombo:
			return self.active ? @"Combo: audio+task+location (active)" : @"Combo: audio+task+location";
	}
	return @"Unknown";
}

@end
