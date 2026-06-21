#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#include "ios_platform.h"

#include <SDL.h>

#include <cmath>
#include <cstring>
#include <stdio.h>

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Write a fatal message to Documents/pvz_log.txt.
/// This is guaranteed to work even before UIApplicationMain is ready.
static void iOS_WriteLog(const char* tag, const char* message)
{
    @autoreleasepool {
        NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (paths.count == 0) {
            NSLog(@"[PvZ][%s] %s", tag, message);
            return;
        }
        NSString* logPath = [paths[0] stringByAppendingPathComponent:@"pvz_log.txt"];
        NSString* entry = [NSString stringWithFormat:@"[%s] %s\n", tag, message];
        NSLog(@"[PvZ][%s] %s", tag, message);

        // Append (create if missing)
        FILE* f = fopen(logPath.fileSystemRepresentation, "a");
        if (f) {
            fputs(entry.UTF8String, f);
            fclose(f);
        }
    }
}

// ---------------------------------------------------------------------------
// Blocking alert (UIAlertController — works on iOS 8+, no deprecation warning)
// ---------------------------------------------------------------------------

/// Must be called on the main thread with an active run loop.
static void iOS_ShowBlockingAlertOnMainThread(const char* title, const char* message)
{
    @autoreleasepool {
        // Always log to file first so we have the message even if UI fails
        iOS_WriteLog(title ? title : "ALERT", message ? message : "");

        NSString* nsTitle   = title   ? [NSString stringWithUTF8String:title]   : @"PvZ Portable";
        NSString* nsMessage = message ? [NSString stringWithUTF8String:message] : @"";

        // Find a presented view controller to host the alert
        UIViewController* rootVC = nil;
        UIWindow* keyWindow = nil;

#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 150000
        // iOS 15+: use windowScene API
        for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene* ws = (UIWindowScene*)scene;
                for (UIWindow* win in ws.windows) {
                    if (!win.isHidden) { keyWindow = win; break; }
                }
                if (keyWindow) break;
            }
        }
#endif
        if (!keyWindow) {
            keyWindow = [UIApplication sharedApplication].keyWindow;
        }
        if (keyWindow) {
            rootVC = keyWindow.rootViewController;
            // Walk to the topmost presented controller
            while (rootVC.presentedViewController)
                rootVC = rootVC.presentedViewController;
        }

        if (!rootVC) {
            // UI isn't ready — already logged to file, nothing more we can do
            NSLog(@"[PvZ] Cannot show alert (no root VC): %@", nsMessage);
            return;
        }

        __block BOOL dismissed = NO;

        UIAlertController* alert =
            [UIAlertController alertControllerWithTitle:nsTitle
                                               message:nsMessage
                                        preferredStyle:UIAlertControllerStyleAlert];

        UIAlertAction* ok = [UIAlertAction actionWithTitle:@"OK"
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction* _) {
            dismissed = YES;
        }];
        [alert addAction:ok];

        [rootVC presentViewController:alert animated:YES completion:nil];

        // Spin the run loop until the user taps OK
        while (!dismissed) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
    }
}

// ---------------------------------------------------------------------------
// Public C API
// ---------------------------------------------------------------------------

extern "C" bool iOS_GetDocumentsPath(char* outPath, size_t outPathSize)
{
    if (outPath == nullptr || outPathSize == 0)
        return false;

    outPath[0] = '\0';

    @autoreleasepool {
        NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (paths.count == 0)
            return false;

        NSString* docs = paths[0];
        if (docs.length == 0)
            return false;

        const char* utf8 = docs.UTF8String;
        if (utf8 == nullptr || utf8[0] == '\0')
            return false;

        strncpy(outPath, utf8, outPathSize - 1);
        outPath[outPathSize - 1] = '\0';
        return true;
    }
}

extern "C" void iOS_WriteLogPublic(const char* tag, const char* message)
{
    iOS_WriteLog(tag, message);
}

extern "C" void iOS_ShowBlockingAlert(const char* title, const char* message)
{
    // Always log first — this works even before UIApplicationMain
    iOS_WriteLog(title ? title : "ALERT", message ? message : "");

    if ([NSThread isMainThread]) {
        iOS_ShowBlockingAlertOnMainThread(title, message);
        return;
    }

    dispatch_sync(dispatch_get_main_queue(), ^{
        iOS_ShowBlockingAlertOnMainThread(title, message);
    });
}

extern "C" bool iOS_WaitForValidScreenBounds(int* outW, int* outH, int maxWaitMs)
{
    const int stepMs = 50;
    int waited = 0;

    while (waited < maxWaitMs)
    {
        @autoreleasepool {
            CGRect bounds = [UIScreen mainScreen].bounds;
            if (bounds.size.width > 0.0f && bounds.size.height > 0.0f &&
                !std::isnan(bounds.size.width) && !std::isnan(bounds.size.height))
            {
                if (outW != nullptr)
                    *outW = (int)bounds.size.width;
                if (outH != nullptr)
                    *outH = (int)bounds.size.height;
                return true;
            }
        }

        SDL_Delay(stepMs);
        SDL_PumpEvents();
        waited += stepMs;
    }

    if (outW != nullptr)
        *outW = 1024;
    if (outH != nullptr)
        *outH = 768;
    return false;
}

/// Safe wrapper around SDL_CreateWindow for iOS.
/// Uses ObjC @try/@catch to prevent CALayerInvalidGeometry (and any other
/// UIKit NSException) from escaping into the SjLj C++ unwinder where it
/// would hit __cxa_bad_cast and cause an unrecoverable abort().
///
/// If the exception is caught, the function logs it and returns NULL so the
/// caller can show a user-facing error instead of crashing silently.
extern "C" SDL_Window* iOS_CreateWindowSafe(
    const char* title, int x, int y, int w, int h, Uint32 flags)
{
    __block SDL_Window* result = nullptr;
    __block NSException* caught = nullptr;

    @try {
        result = SDL_CreateWindow(title, x, y, w, h, flags);
    }
    @catch (NSException* ex) {
        caught = ex;
        result = nullptr;
    }

    if (caught) {
        const char* reason = caught.reason.UTF8String ? caught.reason.UTF8String : "unknown";
        iOS_WriteLog("SDL_CREATE_WINDOW_FAIL", reason);
        // Try again with the most conservative possible settings:
        // 1 px + FULLSCREEN_DESKTOP so UIKit owns everything.
        @try {
            Uint32 safeFlags = (flags & ~SDL_WINDOW_FULLSCREEN) | SDL_WINDOW_FULLSCREEN_DESKTOP;
            result = SDL_CreateWindow(title,
                SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED,
                1, 1, safeFlags);
        }
        @catch (NSException*) {
            result = nullptr;
        }
        if (result)
            iOS_WriteLog("SDL_CREATE_WINDOW_RETRY", "fallback window created OK");
        else
            iOS_WriteLog("SDL_CREATE_WINDOW_RETRY", "fallback window also failed");
    }

    return result;
}
