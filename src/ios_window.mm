#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#include "ios_platform.h"

#include <SDL.h>

#include <cmath>
#include <cstring>
#include <stdio.h>

// ---------------------------------------------------------------------------
// Temporary view controller used to pre-rotate the device to landscape
// BEFORE SDL creates its own window (avoiding orientation-transition NaN).
// ---------------------------------------------------------------------------
@interface SDL_PrerotateVC : UIViewController
@end
@implementation SDL_PrerotateVC
- (NSUInteger)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskLandscape;
}
@end

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
/// UIKit NSException).
///
/// Strategies:
///   1. Normal SDL_CreateWindow
///   2. Create a manual UIWindow with Landscape frame and use SDL_CreateWindowFrom
extern "C" SDL_Window* iOS_CreateWindowSafe(
    const char* title, int x, int y, int w, int h, Uint32 flags)
{
    // Phase 0: Pre-rotation — force the device into landscape BEFORE SDL
    // creates its window.  On iOS 9 at boot the device is in portrait; if
    // SDL's makeKeyAndVisible is the FIRST rotation, the transition can
    // produce "CALayer position contains NaN: [0 nan]".
    @try {
        iOS_WriteLog("SDL_WINDOW_INIT", "prerotating to landscape...");

        UIWindow* preWin = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        preWin.rootViewController = [[SDL_PrerotateVC alloc] init];

        // This triggers the system to evaluate supported orientations:
        // since our VC only allows landscape, the system rotates the device
        // now (before SDL is involved), settling into a stable state.
        [preWin makeKeyAndVisible];

        // Give the run loop time to complete the rotation animation.
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];

        // Tear down the temp window so SDL starts fresh.
        preWin.hidden = YES;
        preWin.rootViewController = nil;
    }
    @catch (NSException* ex) {
        iOS_WriteLog("SDL_PREROTATE_FAIL",
            ex.reason.UTF8String ? ex.reason.UTF8String : "unknown");
    }

    // Strategy 1: normal SDL_CreateWindow (now in stable landscape)
    @try {
        SDL_Window* result = SDL_CreateWindow(title, x, y, w, h, flags);
        if (result) return result;
    }
    @catch (NSException* ex) {
        iOS_WriteLog("SDL_CREATE_WINDOW_FAIL",
            ex.reason.UTF8String ? ex.reason.UTF8String : "unknown");
    }

    // Strategy 2: create a manual UIWindow with explicit Landscape frame
    // and wrap it with SDL_CreateWindowFrom, bypassing SDL's own (broken)
    // window creation on iOS 9.
    iOS_WriteLog("SDL_WINDOW_RETRY", "trying SDL_CreateWindowFrom with manual UIWindow...");
    @try {
        UIWindow* uiWindow = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 1024, 768)];
        uiWindow.hidden = NO;
        SDL_Window* result = SDL_CreateWindowFrom((__bridge void*)uiWindow);
        if (result) {
            iOS_WriteLog("SDL_WINDOW_RETRY", "SDL_CreateWindowFrom OK");
            return result;
        }
        iOS_WriteLog("SDL_WINDOW_RETRY", "SDL_CreateWindowFrom returned null");
    }
    @catch (NSException* ex) {
        iOS_WriteLog("SDL_WINDOW_RETRY",
            ex.reason.UTF8String ? ex.reason.UTF8String : "unknown");
    }

    iOS_WriteLog("SDL_WINDOW_RETRY", "all attempts failed");
    return nullptr;
}

/// Safe wrapper around SDL_GL_CreateContext for iOS.
/// Uses ObjC @try/@catch to prevent any UIKit NSException from escaping
/// into the SjLj C++ unwinder.
extern "C" SDL_GLContext iOS_CreateGLContextSafe(SDL_Window* window)
{
    @try {
        return SDL_GL_CreateContext(window);
    }
    @catch (NSException* ex) {
        const char* reason = ex.reason.UTF8String ? ex.reason.UTF8String : "unknown";
        iOS_WriteLog("SDL_GL_CREATECONTEXT_FAIL", reason);
        return nullptr;
    }
}

/// Top-level @try/@catch wrapper for the game's entry-point function.
/// Catches any ObjC NSException that propagates up from the game loop
/// (e.g. from UIKit callbacks, display link, touch handling) before it
/// reaches the C++ SjLj unwinder where it would trigger __cxa_bad_cast → abort().
///
/// Returns the value returned by `entry`, or 1 if an exception was caught.
extern "C" int iOS_RunWithExceptionCatch(int (*entry)(int, char**), int argc, char** argv)
{
    @autoreleasepool {
        @try {
            return entry(argc, argv);
        }
        @catch (NSException* exception) {
            NSString* desc = [NSString stringWithFormat:
                @"%@: %@\n%@",
                exception.name,
                exception.reason,
                [[exception callStackSymbols] componentsJoinedByString:@"\n"]];
            const char* utf8 = desc.UTF8String ? desc.UTF8String : "unknown exception";
            iOS_WriteLog("FATAL_OBJC_EXCEPTION", utf8);
            NSLog(@"[PvZ OBJC CATCH] %@", desc);
            // Try to show an alert so the user knows something went wrong.
            // If the UI isn't ready, this safely degrades to just logging.
            iOS_ShowBlockingAlert("Fatal Error",
                [[NSString stringWithFormat:@"An unexpected error occurred:\n%@: %@",
                    exception.name, exception.reason] UTF8String]);
            return 1;
        }
    }
}
