#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// JIT via StikDebug. The app asks StikDebug to attach to this process (stikdebug://enable-jit).
// The request is sent at most once per app launch and only when rvvm.autoJIT is on (default on).
// RVVM is never started with "nojit": when JIT is missing, RVVM falls back to the interpreter.
@interface RV64JIT : NSObject

// YES when the kernel reports CS_DEBUGGED for this process (JIT is usable).
+ (BOOL)debuggerAttached;

+ (void)requestJITFromStikDebugIfNeeded;

@end

NS_ASSUME_NONNULL_END
