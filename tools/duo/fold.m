// fold: folds or unfolds an iPhone Duo simulator (iOS 27.1; copied from date-series) by asking SpringBoard's display tool
// service to swap between the cover display and the inner one, as `suiatool swap` does on a device.
// Built and run by tools/duo-fold.sh; runs inside the simulator (`simctl spawn`).
//
//   fold [-position=closed|book|open|0.0-1.0] [-duration=<s>] [-fade | -continuous] [-wait]
//   fold usage      the option text from SpringBoardFoundation
//   fold unlock     release the 10-second testing lock each swap installs
//
// Private API, simulator only, for testing: SpringBoardServices' SBSDisplayToolServiceConnection takes
// the settings struct below; SpringBoardFoundation parses the options. The service needs the
// com.apple.springboard.sbdisplay.service entitlement (see tools/duo-fold.sh).
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// What SBFDisplayToolSwapSettingsFromArguments returns.
typedef struct { double duration; long long orientation; long long profile; BOOL wait; long long targetMode; double position; } ArgSettings;
// What -swapDisplayWithSettings:completionHandler: takes: {state, duration, deviceOrientation,
// profileOverride, waitForCompletion, targetMode, targetHingePosition, lockedForTestingUntil}.
typedef struct { long long state; double duration; long long orientation; long long profile; BOOL wait; long long targetMode; double position; double lockedUntil; } SwapSettings;
typedef ArgSettings (*FromArgsFn)(NSArray *, NSError **);
typedef NSString *(*UsageFn)(void);

int main(int argc, char **argv) {
    @autoreleasepool {
        if (!dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW) ||
            !dlopen("/System/Library/PrivateFrameworks/SpringBoardFoundation.framework/SpringBoardFoundation", RTLD_NOW)) {
            fprintf(stderr, "fold: SpringBoard frameworks not found (an iOS 27 simulator is needed)\n");
            return 2;
        }
        NSMutableArray *args = [NSMutableArray array];
        for (int i = 1; i < argc; i++) [args addObject:@(argv[i])];
        if (args.count == 1 && [args[0] isEqual:@"usage"]) {
            UsageFn usage = (UsageFn)dlsym(RTLD_DEFAULT, "SBFDisplayToolSwapSettingsUsageDescription");
            if (usage) printf("%s\n", usage().UTF8String);
            return usage ? 0 : 2;
        }
        Class connectionClass = NSClassFromString(@"SBSDisplayToolServiceConnection");
        if (!connectionClass) { fprintf(stderr, "fold: no display tool service on this device\n"); return 2; }
        id connection = [connectionClass new];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block int status = 0;
        void (^finished)(id) = ^(id error) {
            if (error) { fprintf(stderr, "fold: %s\n", [error description].UTF8String); status = 1; }
            dispatch_semaphore_signal(done);
        };
        if (args.count == 1 && [args[0] isEqual:@"unlock"]) {
            ((void (*)(id, SEL, id))objc_msgSend)(connection, sel_registerName("unlockForTestingWithCompletion:"), finished);
        } else {
            FromArgsFn fromArgs = (FromArgsFn)dlsym(RTLD_DEFAULT, "SBFDisplayToolSwapSettingsFromArguments");
            if (!fromArgs) { fprintf(stderr, "fold: SBFDisplayToolSwapSettingsFromArguments not found\n"); return 2; }
            NSError *error = nil;
            ArgSettings a = fromArgs(args, &error);
            if (error) { fprintf(stderr, "fold: %s\n", error.localizedDescription.UTF8String); return 2; }
            SwapSettings s = { 0, a.duration, a.orientation, a.profile, a.wait, a.targetMode, a.position, 0 };
            ((void (*)(id, SEL, SwapSettings, id))objc_msgSend)(connection, sel_registerName("swapDisplayWithSettings:completionHandler:"), s, finished);
        }
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) != 0) {
            fprintf(stderr, "fold: no answer from SpringBoard\n");
            return 3;
        }
        return status;
    }
}
