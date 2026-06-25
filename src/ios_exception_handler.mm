#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include "ios_platform.h"

/// Write crash log and optionally show an alert.
/// Safe to call from any thread, including the main thread (no dispatch_sync from main).
void iOSUncaughtExceptionHandler(NSException *exception) {
    NSArray  *arr    = [exception callStackSymbols];
    NSString *reason = [exception reason];
    NSString *name   = [exception name];
    NSString *crashLog = [NSString stringWithFormat:
        @"Exception: %@\nReason: %@\nStack:\n%@", name, reason, [arr componentsJoinedByString:@"\n"]];

    // ---- 1. Write to Documents/crash_exception.txt (always works) ----
    @autoreleasepool {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (paths.count > 0) {
            NSString *logPath = [paths[0] stringByAppendingPathComponent:@"crash_exception.txt"];
            [crashLog writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }

    // ---- 2. Also write to pvz_log.txt via the shared logger ----
    iOS_WriteLogPublic("CRASH", reason.UTF8String ? reason.UTF8String : "unknown exception");

    NSLog(@"[PvZ CRASH] %@", crashLog);

    // ---- 3. Try to show UIAlertController ----
    // DO NOT use dispatch_sync when already on main thread — that deadlocks.
    // iOS_ShowBlockingAlert handles both cases safely.
    iOS_ShowBlockingAlert("Fatal Exception", reason.UTF8String ? reason.UTF8String : "Unknown error");
}

void install_ios_exception_handler() {
    NSSetUncaughtExceptionHandler(&iOSUncaughtExceptionHandler);
}
