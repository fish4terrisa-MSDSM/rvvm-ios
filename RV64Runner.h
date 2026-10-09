#import <Foundation/Foundation.h>
#import <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void RV64SmokeTest(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_BEGIN

extern NSString * const RV64RunnerUARTTextNotification;
extern NSString * const RV64RunnerUARTTextKey;
extern NSString * const RV64RunnerVirtioFSDebugNotification;
extern NSString * const RV64RunnerFramebufferNotification;
extern NSString * const RV64RunnerFramebufferDataKey;
extern NSString * const RV64RunnerFramebufferWidthKey;
extern NSString * const RV64RunnerFramebufferHeightKey;
extern NSString * const RV64RunnerFramebufferStrideKey;
extern NSString * const RV64RunnerFramebufferFormatKey;

/* Defaults keys (shared with the settings UI) */
extern NSString * const RV64DefaultsAttachments;    // NSArray<NSDictionary>: {category, file, readonly, boot}
extern NSString * const RV64DefaultsFirmware;       // NSString: filename in firmware/ or "bundled"
extern NSString * const RV64DefaultsShares;         // NSArray<NSDictionary>: {tag, path}
extern NSString * const RV64DefaultsGPUBackend;     // NSString: none|rutabaga|virgl|venus|virgl-venus
extern NSString * const RV64DefaultsBackgroundMode; // NSString: none|audio|task|location|combo

@interface RV64Runner : NSObject
+ (void)startLinux;
+ (void)requestRestart;
+ (void)reinitNetwork;
+ (BOOL)saveSnapshot:(NSString * _Nullable * _Nullable)errorOut;
+ (BOOL)loadSnapshot:(NSString * _Nullable * _Nullable)errorOut;
+ (BOOL)reinitNetwork:(NSString * _Nullable * _Nullable)errorOut;
+ (void)sendConsoleBytes:(NSData * _Nullable)data;
+ (void)sendConsoleText:(NSString * _Nullable)text;
+ (uint32_t)framebufferSeq;
+ (void)framebufferMetaWidth:(uint32_t * _Nullable)widthOut
                     height:(uint32_t * _Nullable)heightOut
                     stride:(uint32_t * _Nullable)strideOut
                     format:(uint32_t * _Nullable)formatOut
                     offset:(uint32_t * _Nullable)offsetOut;
+ (BOOL)copyFramebufferBGRA:(NSMutableData *)outData
                   width:(NSUInteger * _Nullable)widthOut
                  height:(NSUInteger * _Nullable)heightOut
             bytesPerRow:(NSUInteger * _Nullable)bytesPerRowOut;
+ (void)sendVirtioText:(NSString * _Nullable)text;
+ (void)sendVirtioText:(NSString * _Nullable)text
                ctrl:(BOOL)ctrl
                 alt:(BOOL)alt;
+ (void)sendVirtioKey:(uint8_t)hidKey
              shift:(BOOL)shift
               ctrl:(BOOL)ctrl
                alt:(BOOL)alt;
+ (void)sendVirtioMouseDeltaX:(int32_t)dx deltaY:(int32_t)dy;
+ (void)setVirtioMouseResolutionWidth:(uint32_t)width height:(uint32_t)height;
+ (void)sendVirtioMouseAbsX:(int32_t)x absY:(int32_t)y;
+ (void)sendVirtioMouseButtons:(uint8_t)btnMask down:(BOOL)down;
+ (void)sendVirtioMouseScroll:(int32_t)offset;
+ (void)setVirtioFSDebugToUARTEnabled:(BOOL)enabled;
+ (NSArray<NSString *> *)virtioFSDebugLines;
+ (void)clearVirtioFSDebug;

/* Touch input (framebuffer mode): absolute touch -> virtio mouse/touchscreen */
+ (void)sendTouchAtX:(float)x
                   y:(float)y
               phase:(NSInteger)phase /* 0=begin 1=move 2=end 3=cancel */
               tapCount:(NSUInteger)tapCount;

/* Boot attachment management ({category, file, readonly, boot}) */
+ (NSArray<NSDictionary *> *)attachments;
+ (void)setAttachments:(NSArray<NSDictionary *> *)attachments;

/* Firmware selection ("bundled" or filename inside Documents/firmware) */
+ (NSString *)selectedFirmware;
+ (void)setSelectedFirmware:(NSString *)name;

/* virtio-fs shares ({tag, path}) */
+ (NSArray<NSDictionary *> *)shares;
+ (void)setShares:(NSArray<NSDictionary *> *)shares;

/* GPU backend: none|rutabaga|virgl|venus|virgl-venus */
+ (NSString *)gpuBackend;
+ (void)setGpuBackend:(NSString *)backend;

/* Whether the compiled VM has JIT available (always compiled in; runtime
 * fallback to the interpreter happens inside RVVM if RWX is unavailable) */
+ (BOOL)jitCompiledIn;

@end

NS_ASSUME_NONNULL_END
