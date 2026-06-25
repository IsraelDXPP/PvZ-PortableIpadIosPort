#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

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
///
/// Phases:
///   0. Swizzle CALayer.setPosition: to suppress NaN values
///   1. Pre-rotate the device to landscape before SDL window creation
///   2. Normal SDL_CreateWindow
///   3. Manual UIWindow fallback via SDL_CreateWindowFrom
///
/// Silently fix NaN values in a CGPoint by replacing them with the other
/// coordinate (or 0 if both are NaN).  Returns YES if a fix was applied.
static BOOL iOS_FixNaNPoint(CGPoint* p)
{
    BOOL fixed = NO;
    if (isnan(p->x) && isnan(p->y)) {
        p->x = 0; p->y = 0; fixed = YES;
    } else if (isnan(p->x)) {
        p->x = p->y; fixed = YES;
    } else if (isnan(p->y)) {
        p->y = p->x; fixed = YES;
    }
    return fixed;
}

/// Original CALayer.setPosition: IMP, saved before we swizzle it.
static void (*gOrigSetPosition)(id, SEL, CGPoint);

/// Swizzled replacement for CALayer.setPosition: that silently replaces
/// NaN coordinates with 0 to prevent "CALayer position contains NaN".
static void iOS_SwizzledSetPosition(id self, SEL _cmd, CGPoint position)
{
    iOS_FixNaNPoint(&position);
    gOrigSetPosition(self, _cmd, position);
}

/// Whether the CALayer.setPosition: swizzle is currently active.
static BOOL gSwizzleActive = NO;

/// Install a temporary swizzle on CALayer.setPosition: that filters NaN.
/// Call iOS_UnswizzleSetPosition() to restore the original.
static void iOS_SwizzleSetPosition(void)
{
    if (gSwizzleActive) return;
    gSwizzleActive = YES;

    Method m = class_getInstanceMethod([CALayer class], @selector(setPosition:));
    gOrigSetPosition = (void (*)(id, SEL, CGPoint))method_getImplementation(m);
    method_setImplementation(m, (IMP)iOS_SwizzledSetPosition);
}

/// Restore the original CALayer.setPosition: implementation.
static void iOS_UnswizzleSetPosition(void)
{
    if (!gSwizzleActive) return;
    gSwizzleActive = NO;

    Method m = class_getInstanceMethod([CALayer class], @selector(setPosition:));
    method_setImplementation(m, (IMP)gOrigSetPosition);
    gOrigSetPosition = nil;
}

extern "C" SDL_Window* iOS_CreateWindowSafe(
    const char* title, int x, int y, int w, int h, Uint32 flags)
{
    // --- Phase 0: NaN swizzle ---
    // Keep CALayer.setPosition: swizzle active throughout window/GL setup to
    // prevent CALayerInvalidGeometry from escaping into the SjLj unwinder.
    iOS_SwizzleSetPosition();

    // --- Phase 1: Create window HIDDEN ---
    // On iPad mini 1 (iOS 9) UIScreen.bounds is 0×0 at this point.
    // Creating the window HIDDEN means SDL skips makeKeyAndVisible, which
    // prevents the "divide-by-zero → NaN CALayer" crash during first layout.
    Uint32 hiddenFlags = (flags | SDL_WINDOW_HIDDEN) & ~SDL_WINDOW_SHOWN;

    SDL_Window* result = nullptr;
    @try {
        iOS_WriteLog("SDL_WINDOW_INIT", "creating HIDDEN window to bypass zero-size issue");
        result = SDL_CreateWindow(title, x, y, w, h, hiddenFlags);
        if (result)
            iOS_WriteLog("SDL_WINDOW_OK", "SDL window created (HIDDEN)");
        else
            iOS_WriteLog("SDL_CREATE_WINDOW_FAIL", SDL_GetError() ?: "null");
    }
    @catch (NSException* ex) {
        iOS_WriteLog("SDL_CREATE_WINDOW_EXCEPTION",
            ex.reason.UTF8String ?: "unknown");
    }

    if (!result) {
        iOS_UnswizzleSetPosition();
        return nullptr;
    }

    // --- Phase 2: Force valid frame on all UIWindows before show ---
    //
    // At this point keyWindow may still be nil (because we used HIDDEN).
    // We iterate ALL windows and force 1024×768 (iPad mini 1 landscape).
    //
    // Why hardcode 1024×768?  Because UIScreen.bounds is 0×0 or NaN at this
    // point on iOS 9 iPad mini 1 — we cannot query the real size.  1024×768
    // is the only landscape resolution that iPad mini 1 has, so this is safe.
    // The value is sanity-checked after GL context creation in UpdateViewport().
    @try {
        NSArray<UIWindow*>* allWindows = [UIApplication sharedApplication].windows;
        if (allWindows.count == 0) {
            iOS_WriteLog("SDL_FORCE_FRAME", "no UIWindows found in UIApplication.windows");
        } else {
            CGRect targetFrame = CGRectMake(0, 0, 1024, 768);
            for (UIWindow* win in allWindows) {
                // Force the UIWindow
                win.frame = targetFrame;
                [win layoutIfNeeded];

                // Force the root view controller's view
                UIView* rootView = win.rootViewController.view;
                if (rootView) {
                    rootView.frame = targetFrame;
                    [rootView layoutIfNeeded];

                    // Force the SDL CAEAGLLayer view (direct child of root)
                    for (UIView* sub in rootView.subviews) {
                        sub.frame = targetFrame;
                        [sub layoutIfNeeded];
                        // Recurse one level for SDL's internal view hierarchy
                        for (UIView* subsub in sub.subviews) {
                            subsub.frame = targetFrame;
                            [subsub layoutIfNeeded];
                        }
                    }
                }

                char dbg[256];
                snprintf(dbg, sizeof(dbg),
                    "forced win=%.0fx%.0f rootView=%.0fx%.0f",
                    win.bounds.size.width, win.bounds.size.height,
                    win.rootViewController.view
                        ? win.rootViewController.view.bounds.size.width : 0,
                    win.rootViewController.view
                        ? win.rootViewController.view.bounds.size.height : 0);
                iOS_WriteLog("SDL_FORCE_FRAME", dbg);
            }
        }
    }
    @catch (NSException* ex) {
        iOS_WriteLog("SDL_FORCE_FRAME_FAIL", ex.reason.UTF8String ?: "unknown");
    }

    // --- Phase 3: Show window (makeKeyAndVisible) ---
    // Views now have valid frames, so CoreAnimation layout will not produce NaN.
    @try {
        SDL_ShowWindow(result);
        iOS_WriteLog("SDL_WINDOW_SHOWN", "SDL_ShowWindow OK");
    }
    @catch (NSException* ex) {
        iOS_WriteLog("SDL_SHOW_WINDOW_FAIL", ex.reason.UTF8String ?: "unknown");
    }

    // Swizzle stays active for GL context creation (Phase 4 in iOS_CreateGLContextSafe).
    return result;
}

/// Safe wrapper around SDL_GL_CreateContext for iOS.
///
/// Continues the NaN-suppression swizzle started by iOS_CreateWindowSafe
/// so that setSDLWindow: / layoutSubviews inside GL context creation don't
/// trigger a CALayerInvalidGeometry exception on iOS 9.
///
/// Returns the context, or nullptr on failure (with SDL_GetError() logged).
extern "C" SDL_GLContext iOS_CreateGLContextSafe(SDL_Window* window)
{
    @try {
        // Ensure swizzle is active
        if (!gSwizzleActive)
            iOS_SwizzleSetPosition();

        // --- Re-force frames before every GL context attempt ---
        // On iOS 9 iPad mini 1, the CAEAGLLayer drawable requires a non-zero
        // frame.  Even after SDL_ShowWindow, the layer may still be 0×0 or NaN.
        // Force all UIWindows + subviews to 1024×768 on every attempt.
        CGRect targetFrame = CGRectMake(0, 0, 1024, 768);
        NSArray<UIWindow*>* allWins = [UIApplication sharedApplication].windows;
        UIWindow* kw = [UIApplication sharedApplication].keyWindow;

        for (UIWindow* win in allWins) {
            if (win.bounds.size.width <= 0 || win.bounds.size.height <= 0 ||
                std::isnan(win.bounds.size.width) || std::isnan(win.bounds.size.height))
            {
                win.frame = targetFrame;
                [win layoutIfNeeded];

                UIView* rv = win.rootViewController.view;
                if (rv) {
                    rv.frame = targetFrame;
                    [rv layoutIfNeeded];
                    for (UIView* sub in rv.subviews) {
                        sub.frame = targetFrame;
                        [sub layoutIfNeeded];
                        for (UIView* subsub in sub.subviews) {
                            subsub.frame = targetFrame;
                            [subsub layoutIfNeeded];
                        }
                    }
                }
            }
        }

        // Log current state so we can track what changed
        {
            char buf[256];
            UIWindow* logWin = kw ?: (allWins.count > 0 ? allWins[0] : nil);
            if (logWin) {
                const char* orStr = "?";
                UIInterfaceOrientation orientVal = [UIApplication sharedApplication].statusBarOrientation;
                if (orientVal == UIInterfaceOrientationLandscapeLeft)  orStr = "LL";
                else if (orientVal == UIInterfaceOrientationLandscapeRight) orStr = "LR";
                else if (orientVal == UIInterfaceOrientationPortrait)  orStr = "P";
                else if (orientVal == UIInterfaceOrientationPortraitUpsideDown) orStr = "PD";

                snprintf(buf, sizeof(buf),
                    "keyWindow bounds at GL: %.0fx%.0f frame=(%.0f,%.0f,%.0f,%.0f) "
                    "screen=%.0fx%.0f or=%s",
                    logWin.bounds.size.width, logWin.bounds.size.height,
                    logWin.frame.origin.x, logWin.frame.origin.y,
                    logWin.frame.size.width, logWin.frame.size.height,
                    [UIScreen mainScreen].bounds.size.width,
                    [UIScreen mainScreen].bounds.size.height,
                    orStr);
                iOS_WriteLog("SDL_GL_DEBUG", buf);
            } else {
                iOS_WriteLog("SDL_GL_DEBUG", "no window found");
            }
        }

        // Spin the run loop briefly so CoreAnimation commits the frame changes
        // before EAGL tries to create the drawable surface.
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];

        SDL_GLContext ctx = SDL_GL_CreateContext(window);

        if (!ctx) {
            const char* sdlErr = SDL_GetError();
            iOS_WriteLog("SDL_GL_CREATECONTEXT_FAIL",
                sdlErr ? sdlErr : "SDL_GL_CreateContext returned NULL");
            // Leave swizzle active — caller retries
        } else {
            // Success — remove swizzle
            iOS_UnswizzleSetPosition();
        }

        return ctx;
    }
    @catch (NSException* ex) {
        const char* reason = ex.reason.UTF8String ? ex.reason.UTF8String : "unknown";
        iOS_WriteLog("SDL_GL_CREATECONTEXT_EXCEPTION", reason);
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
