#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/*
 * RV64BackgroundKeeper
 *
 * Keeps the VM running while the app is backgrounded. iOS suspends apps
 * shortly after backgrounding unless one of the approved background modes
 * keeps the process alive. Multiple strategies are implemented; the user
 * chooses one (or "combo") in Settings:
 *
 *   none       - system default (VM pauses when suspended)
 *   audio      - silent audio session loop (UIBackgroundModes: audio)
 *   task       - chained UIBackgroundTask renewal (grace periods)
 *   location   - significant-change location monitoring (UIBackgroundModes: location)
 *   combo      - audio + task + location together (most resilient)
 *
 * All strategies are real implementations backed by the corresponding
 * system APIs; availability depends on the entitlements granted at signing.
 */

typedef NS_ENUM(NSInteger, RV64BackgroundStrategy) {
	RV64BackgroundStrategyNone = 0,
	RV64BackgroundStrategyAudio = 1,
	RV64BackgroundStrategyTask = 2,
	RV64BackgroundStrategyLocation = 3,
	RV64BackgroundStrategyCombo = 4,
};

@interface RV64BackgroundKeeper : NSObject

+ (instancetype)shared;

/* Which strategy is configured (persisted by the caller via NSUserDefaults) */
@property (nonatomic, assign) RV64BackgroundStrategy strategy;

/* Start/stop keeping the app alive */
- (void)start;
- (void)stop;

/* Human-readable status for the settings UI */
- (NSString *)statusText;

/* Whether the current strategy is actively holding the app */
@property (nonatomic, readonly) BOOL active;

/* Called when the system is about to suspend us anyway */
@property (nonatomic, copy, nullable) void (^onExpiry)(void);

@end

NS_ASSUME_NONNULL_END
