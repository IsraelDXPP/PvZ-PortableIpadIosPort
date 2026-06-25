#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include "ios_platform.h"

#include <SDL.h>
#include <SDL_syswm.h>

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
// iPad / UIKit layout helpers
// ---------------------------------------------------------------------------

static BOOL iOS_IsPad(void)
{
    return [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;
}

static BOOL iOS_SizeIsValid(CGSize size)
{
    return size.width > 0.0f && size.height > 0.0f &&
           !std::isnan(size.width) && !std::isnan(size.height);
}

static void iOS_PumpRunLoopMs(int ms)
{
    const int stepMs = 16;
    int waited = 0;
    while (waited < ms) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:stepMs / 1000.0]];
        SDL_PumpEvents();
        waited += stepMs;
    }
}

/// Try several UIKit sources for the current screen size in points.
static BOOL iOS_MeasureScreenSize(CGSize* outSize)
{
    UIScreen* screen = [UIScreen mainScreen];
    if (!screen)
        return NO;

    CGRect bounds = screen.bounds;
    if (iOS_SizeIsValid(bounds.size)) {
        *outSize = bounds.size;
        return YES;
    }

    if ([screen respondsToSelector:@selector(nativeBounds)]) {
        CGRect native = screen.nativeBounds;
        CGFloat scale = screen.scale > 0.0f ? screen.scale : 1.0f;
        CGSize points = CGSizeMake(native.size.width / scale, native.size.height / scale);
        if (iOS_SizeIsValid(points)) {
            *outSize = points;
            return YES;
        }
    }

    CGSize mode = screen.currentMode.size;
    if (mode.width > 0.0f && mode.height > 0.0f) {
        CGFloat scale = screen.scale > 0.0f ? screen.scale : 1.0f;
        CGSize points = CGSizeMake(mode.width / scale, mode.height / scale);
        if (iOS_SizeIsValid(points)) {
            *outSize = points;
            return YES;
        }
    }

    return NO;
}

static UIWindow* iOS_GetSDLUIWindow(SDL_Window* window)
{
    if (!window)
        return nil;

    SDL_SysWMinfo info;
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(window, &info))
        return nil;

#if defined(SDL_SYSWM_UIKIT)
    if (info.subsystem == SDL_SYSWM_UIKIT)
        return info.info.uikit.window;
#endif
    return nil;
}

static UIWindow* iOS_FindActiveWindow(SDL_Window* sdlWindow)
{
    UIWindow* win = iOS_GetSDLUIWindow(sdlWindow);
    if (win)
        return win;

    win = [UIApplication sharedApplication].keyWindow;
    if (win)
        return win;

    NSArray<UIWindow*>* wins = [UIApplication sharedApplication].windows;
    return wins.count > 0 ? wins[0] : nil;
}

/// On iPad, UIWindow bounds can stay 0×0 until UIKit finishes launch layout.
/// Resize the SDL UIWindow from the real UIScreen bounds once they are known.
static BOOL iOS_SyncWindowToScreen(SDL_Window* sdlWindow, UIWindow* uiWindow)
{
    CGSize screenSize;
    if (!iOS_MeasureScreenSize(&screenSize))
        return NO;

    UIScreen* screen = [UIScreen mainScreen];
    CGRect target = screen.bounds;
    if (!iOS_SizeIsValid(target.size))
        target = CGRectMake(0, 0, screenSize.width, screenSize.height);

    if (uiWindow) {
        if (!iOS_SizeIsValid(uiWindow.bounds.size))
            uiWindow.frame = target;
        [uiWindow makeKeyAndVisible];
        [uiWindow layoutIfNeeded];

        UIView* rootView = uiWindow.rootViewController.view;
        if (rootView && !iOS_SizeIsValid(rootView.bounds.size)) {
            rootView.frame = uiWindow.bounds;
            [rootView setNeedsLayout];
            [rootView layoutIfNeeded];
        }
    }

    if (sdlWindow) {
        int w = (int)target.size.width;
        int h = (int)target.size.height;
        if (uiWindow && iOS_SizeIsValid(uiWindow.bounds.size)) {
            w = (int)uiWindow.bounds.size.width;
            h = (int)uiWindow.bounds.size.height;
        }
        SDL_SetWindowSize(sdlWindow, w, h);
    }

    return uiWindow ? iOS_SizeIsValid(uiWindow.bounds.size) : iOS_SizeIsValid(target.size);
}

/// Pump the main run loop until the SDL window (or UIScreen) has non-zero bounds.
/// iPad-only: iPhone launch layout is already reliable enough.
static BOOL iOS_WaitForWindowLayout(SDL_Window* sdlWindow, int maxWaitMs)
{
    if (!iOS_IsPad())
        return YES;

    const int stepMs = 50;
    int waited = 0;

    while (waited < maxWaitMs) {
        @autoreleasepool {
            UIWindow* uiWindow = iOS_FindActiveWindow(sdlWindow);
            if (uiWindow && iOS_SizeIsValid(uiWindow.bounds.size))
                return YES;

            if (iOS_SyncWindowToScreen(sdlWindow, uiWindow)) {
                iOS_PumpRunLoopMs(stepMs);
                uiWindow = iOS_FindActiveWindow(sdlWindow);
                if (uiWindow && iOS_SizeIsValid(uiWindow.bounds.size))
                    return YES;
            }
        }

        iOS_PumpRunLoopMs(stepMs);
        waited += stepMs;
    }

    return NO;
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
    if (outW != nullptr)
        *outW = 0;
    if (outH != nullptr)
        *outH = 0;

    const int stepMs = 50;
    int waited = 0;

    while (waited < maxWaitMs)
    {
        @autoreleasepool {
            CGSize size;
            if (iOS_MeasureScreenSize(&size)) {
                if (outW != nullptr)
                    *outW = (int)size.width;
                if (outH != nullptr)
                    *outH = (int)size.height;
                return true;
            }
        }

        iOS_PumpRunLoopMs(stepMs);
        waited += stepMs;
    }

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
    // --- NaN swizzle (install BEFORE SDL touches any CALayer) ---
    //
    // On iOS 9 iPad mini 1, UIScreen.mainScreen.bounds is 0×0 at the moment
    // SDL creates the UIWindow.  SDL passes this 0×0 frame to the UIWindow
    // and its CALayer.  When UIKit tries to make this the key window
    // (makeKeyAndVisible) it calls [CALayer setPosition:] with position.y = NaN
    // (0 / 0 = NaN from a frame calculation).  This throws CALayerInvalidGeometry
    // which, through the SjLj C++ unwinder (-fsjlj-exceptions), becomes
    // __cxa_bad_cast → abort().
    //
    // The swizzle replaces NaN coordinates with 0 BEFORE the throw, so the
    // exception never happens.
    //
    // WHY NOT SDL_WINDOW_HIDDEN?
    //   Hiding the window skips makeKeyAndVisible.  Without makeKeyAndVisible
    //   UIKit never makes this UIWindow the key window, so UIScreen.mainScreen.bounds
    //   stays 0×0 forever.  EAGL requires a valid non-zero layer size to create
    //   an OpenGL ES drawable — it fails every retry because bounds are always 0.
    //
    // The correct fix is: swizzle + VISIBLE window.  The swizzle prevents the
    // NaN crash; a visible (key) window lets UIKit resolve UIScreen bounds.
    iOS_SwizzleSetPosition();
    iOS_WriteLog("SDL_WINDOW_INIT", "creating VISIBLE window (swizzle guards NaN)");

    SDL_Window* result = nullptr;
    @try {
        result = SDL_CreateWindow(title, x, y, w, h, flags);
        if (result) {
            // Log the actual window/screen state so we can verify bounds resolved.
            UIWindow* kw = [UIApplication sharedApplication].keyWindow;
            char dbg[256];
            snprintf(dbg, sizeof(dbg),
                "win=%p keyWin=%.0fx%.0f screen=%.0fx%.0f",
                (void*)result,
                kw ? kw.bounds.size.width  : 0,
                kw ? kw.bounds.size.height : 0,
                [UIScreen mainScreen].bounds.size.width,
                [UIScreen mainScreen].bounds.size.height);
            iOS_WriteLog("SDL_WINDOW_OK", dbg);
        } else {
            iOS_WriteLog("SDL_CREATE_WINDOW_FAIL", SDL_GetError() ?: "null");
        }
    }
    @catch (NSException* ex) {
        iOS_WriteLog("SDL_CREATE_WINDOW_EXCEPTION",
            ex.reason.UTF8String ?: "unknown");
        iOS_UnswizzleSetPosition();
        return nullptr;
    }

    // Swizzle stays active until iOS_CreateGLContextSafe succeeds.
    if (result && iOS_IsPad()) {
        const bool layoutReady = iOS_WaitForWindowLayout(result, 3000);
        UIWindow* kw = iOS_FindActiveWindow(result);
        char dbg[256];
        snprintf(dbg, sizeof(dbg),
            "layout=%s win=%p keyWin=%.0fx%.0f screen=%.0fx%.0f",
            layoutReady ? "OK" : "TIMEOUT",
            (void*)result,
            kw ? kw.bounds.size.width  : 0,
            kw ? kw.bounds.size.height : 0,
            [UIScreen mainScreen].bounds.size.width,
            [UIScreen mainScreen].bounds.size.height);
        iOS_WriteLog("SDL_WINDOW_LAYOUT", dbg);
    }

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

        UIWindow* kw = iOS_FindActiveWindow(window);
        NSArray<UIWindow*>* allWins = [UIApplication sharedApplication].windows;

        // iPad: EAGL needs a non-zero CAEAGLLayer. Wait for real UIKit layout first.
        if (iOS_IsPad()) {
            if (!iOS_WaitForWindowLayout(window, 500)) {
                iOS_SyncWindowToScreen(window, kw);
                iOS_PumpRunLoopMs(50);
                kw = iOS_FindActiveWindow(window);
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

        // Spin the run loop so CoreAnimation commits layout before EAGL allocation.
        iOS_PumpRunLoopMs(50);

        // Do not attempt GL on iPad while the drawable is still zero-sized.
        if (iOS_IsPad()) {
            kw = iOS_FindActiveWindow(window);
            if (!kw || !iOS_SizeIsValid(kw.bounds.size)) {
                iOS_WriteLog("SDL_GL_CREATECONTEXT_FAIL",
                    "iPad window bounds still zero — waiting for UIKit layout");
                return nullptr;
            }
        }

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
