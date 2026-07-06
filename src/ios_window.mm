#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>

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

static BOOL iOS_SizeIsValid(CGSize size)
{
    return size.width > 0.0f && size.height > 0.0f &&
           !std::isnan(size.width) && !std::isnan(size.height);
}

static CGSize gSanitizeFallbackSize = {0, 0};
static UIWindow* gForcedUIWindow = nil;

static void iOS_LogSize(char* buf, size_t bufSize, const char* label, CGSize size)
{
    if (isnan(size.width) || isnan(size.height)) {
        snprintf(buf, bufSize, "%s=nan", label);
    } else {
        snprintf(buf, bufSize, "%s=%.0fx%.0f", label, (double)size.width, (double)size.height);
    }
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
        gSanitizeFallbackSize = bounds.size;
        return YES;
    }

    if ([screen respondsToSelector:@selector(nativeBounds)]) {
        CGRect native = screen.nativeBounds;
        CGFloat scale = screen.scale > 0.0f ? screen.scale : 1.0f;
        CGSize points = CGSizeMake(native.size.width / scale, native.size.height / scale);
        if (iOS_SizeIsValid(points)) {
            *outSize = points;
            gSanitizeFallbackSize = points;
            return YES;
        }
    }

    CGSize mode = screen.currentMode.size;
    if (mode.width > 0.0f && mode.height > 0.0f) {
        CGFloat scale = screen.scale > 0.0f ? screen.scale : 1.0f;
        CGSize points = CGSizeMake(mode.width / scale, mode.height / scale);
        if (iOS_SizeIsValid(points)) {
            *outSize = points;
            gSanitizeFallbackSize = points;
            return YES;
        }
    }

    // Largest mode from availableModes (works before bounds are initialised).
    CGSize best = {0, 0};
    for (UIScreenMode* sm in screen.availableModes) {
        CGSize ms = sm.size;
        if (ms.width <= 0.0f || ms.height <= 0.0f)
            continue;
        if (ms.width * ms.height > best.width * best.height)
            best = ms;
    }
    if (best.width > 0.0f && best.height > 0.0f) {
        CGFloat scale = screen.scale > 0.0f ? screen.scale : 1.0f;
        CGSize points = CGSizeMake(best.width / scale, best.height / scale);
        if (iOS_SizeIsValid(points)) {
            *outSize = points;
            gSanitizeFallbackSize = points;
            return YES;
        }
    }

    // Last resort: hardcoded fallback.
    // UIKit sometimes keeps UIScreen.bounds at {0,0} on iOS 9 iPad
    // even after applicationDidBecomeActive — every UIKit query above
    // fails and we still have no size.
    // If we reached here, all UIKit methods returned zero — this is
    // the iOS-9-iPad-bounds-never-settle bug.  On iPhones UIKit always
    // reports valid bounds, so a hardcoded 1024×768 (iPad landscape
    // points) is the correct universal fallback.
    //
    // Note: [UIDevice currentDevice].userInterfaceIdiom can return
    // UIUserInterfaceIdiomPhone even on a real iPad (Mini 1, iOS 9.3.6)
    // when called during early launch, so we don't branch on it.
    *outSize = CGSizeMake(1024, 768);
    gSanitizeFallbackSize = *outSize;
    iOS_WriteLog("SCREEN_FALLBACK", "1024x768 (hardcoded)");
    return YES;
}

/// Block until UIApplicationStateActive (or timeout).
static void iOS_WaitUntilApplicationActive(int maxWaitMs)
{
    const int stepMs = 50;
    int waited = 0;

    while (waited < maxWaitMs) {
        @autoreleasepool {
            UIApplication* app = [UIApplication sharedApplication];
            if (app && app.applicationState == UIApplicationStateActive) {
                iOS_WriteLog("IOS_ACTIVE", "UIApplicationStateActive");
                return;
            }
        }
        iOS_PumpRunLoopMs(stepMs);
        waited += stepMs;
    }

    iOS_WriteLog("IOS_ACTIVE", "TIMEOUT waiting for UIApplicationStateActive");
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
    if (win && iOS_SizeIsValid(win.bounds.size))
        return win;

    win = [UIApplication sharedApplication].keyWindow;
    if (win && iOS_SizeIsValid(win.bounds.size))
        return win;

    NSArray<UIWindow*>* wins = [UIApplication sharedApplication].windows;
    for (UIWindow* w in wins) {
        if (iOS_SizeIsValid(w.bounds.size))
            return w;
    }

    return gForcedUIWindow;
}

/// Bootstrap a UIWindow with real dimensions from UIScreen.currentMode, then
/// hand it to SDL via CreateWindowFrom.  Avoids SDL_CreateWindow reading 0×0
/// UIScreen.bounds on iOS 9 iPad at launch (which produces NaN CALayer frames).
static SDL_Window* iOS_TryCreateWindowFromUIKit(void)
{
    UIScreen* screen = [UIScreen mainScreen];
    if (screen) {
        (void)screen.availableModes;
        (void)screen.currentMode;
        if ([screen respondsToSelector:@selector(coordinateSpace)])
            (void)screen.coordinateSpace;
    }

    CGSize size = {0, 0};
    for (int i = 0; i < 100 && !iOS_MeasureScreenSize(&size); i++)
        iOS_PumpRunLoopMs(50);

    if (!iOS_SizeIsValid(size)) {
        iOS_WriteLog("CREATEFROM_FAIL", "no screen size from UIKit");
        return nullptr;
    }

    // Landscape game — prefer the larger axis as width.
    if (size.width < size.height) {
        const CGFloat t = size.width;
        size.width = size.height;
        size.height = t;
    }

    const CGRect frame = CGRectMake(0, 0, size.width, size.height);
    UIWindow* uiWindow = [[UIWindow alloc] initWithFrame:frame];
    if (!uiWindow) {
        iOS_WriteLog("CREATEFROM_FAIL", "UIWindow alloc failed");
        return nullptr;
    }

    UIViewController* vc = [[UIViewController alloc] init];
    vc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    vc.view.frame = frame;
    uiWindow.rootViewController = vc;
    [uiWindow makeKeyAndVisible];
    [uiWindow layoutIfNeeded];

    char dbg[160];
    char szBuf[48];
    iOS_LogSize(szBuf, sizeof(szBuf), "frame", frame.size);
    snprintf(dbg, sizeof(dbg), "CreateWindowFrom %s winBounds=%.0fx%.0f",
        szBuf, uiWindow.bounds.size.width, uiWindow.bounds.size.height);
    iOS_WriteLog("CREATEFROM", dbg);

    SDL_Window* sdlWin = SDL_CreateWindowFrom((__bridge void*)uiWindow);
    if (!sdlWin)
        iOS_WriteLog("CREATEFROM_FAIL", SDL_GetError() ?: "SDL_CreateWindowFrom null");
    return sdlWin;
}

/// UIWindow bounds can stay 0×0 until UIKit finishes launch layout.
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

/// Pump the main run loop until the SDL window has non-zero bounds.
static BOOL iOS_WaitForWindowLayout(SDL_Window* sdlWindow, int maxWaitMs)
{
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

/// Replace NaN / non-positive sizes in a CGRect using the last measured screen size.
static void iOS_FixNaNRect(CGRect* r)
{
    CGSize fb = gSanitizeFallbackSize;
    if (!iOS_SizeIsValid(fb))
        iOS_MeasureScreenSize(&fb);

    if (isnan(r->origin.x) || isinf(r->origin.x)) r->origin.x = 0;
    if (isnan(r->origin.y) || isinf(r->origin.y)) r->origin.y = 0;

    if (isnan(r->size.width) || isinf(r->size.width) || r->size.width <= 0.0f) {
        if (iOS_SizeIsValid(fb)) r->size.width = fb.width;
    }
    if (isnan(r->size.height) || isinf(r->size.height) || r->size.height <= 0.0f) {
        if (iOS_SizeIsValid(fb)) r->size.height = fb.height;
    }

    // If one axis is still bad, mirror the valid axis (square fallback).
    if ((r->size.width <= 0.0f || isnan(r->size.width)) && r->size.height > 0.0f)
        r->size.width = r->size.height;
    if ((r->size.height <= 0.0f || isnan(r->size.height)) && r->size.width > 0.0f)
        r->size.height = r->size.width;
}

static void (*gOrigSetPosition)(id, SEL, CGPoint);
static void (*gOrigLayerSetFrame)(id, SEL, CGRect);
static void (*gOrigLayerSetBounds)(id, SEL, CGRect);
static void (*gOrigViewSetFrame)(id, SEL, CGRect);
static void (*gOrigViewSetBounds)(id, SEL, CGRect);

static void iOS_SwizzledSetPosition(id self, SEL _cmd, CGPoint position)
{
    iOS_FixNaNPoint(&position);
    gOrigSetPosition(self, _cmd, position);
}

static void iOS_SwizzledLayerSetFrame(id self, SEL _cmd, CGRect frame)
{
    iOS_FixNaNRect(&frame);
    gOrigLayerSetFrame(self, _cmd, frame);
}

static void iOS_SwizzledLayerSetBounds(id self, SEL _cmd, CGRect bounds)
{
    iOS_FixNaNRect(&bounds);
    gOrigLayerSetBounds(self, _cmd, bounds);
}

static void iOS_SwizzledViewSetFrame(id self, SEL _cmd, CGRect frame)
{
    iOS_FixNaNRect(&frame);
    gOrigViewSetFrame(self, _cmd, frame);
}

static void iOS_SwizzledViewSetBounds(id self, SEL _cmd, CGRect bounds)
{
    iOS_FixNaNRect(&bounds);
    gOrigViewSetBounds(self, _cmd, bounds);
}

static BOOL gSwizzleActive = NO;

// ---------------------------------------------------------------------------
// UIScreen bounds swizzle — override the broken 0×0 that iOS 9 iPad returns
// so that SDL (and any UIKit code) always sees valid geometry.
// ---------------------------------------------------------------------------

static CGRect (*gOrigUIScreenBounds)(id, SEL);

static CGRect iOS_SwizzledUIScreenBounds(id self, SEL _cmd)
{
    CGRect orig = gOrigUIScreenBounds(self, _cmd);
    if (orig.size.width <= 0.0f || orig.size.height <= 0.0f ||
        isnan(orig.size.width) || isnan(orig.size.height)) {
        return CGRectMake(0, 0, 1024, 768);
    }
    return orig;
}

static void iOS_SwizzleUIScreenBounds(void)
{
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;

    Method m = class_getInstanceMethod([UIScreen class], @selector(bounds));
    gOrigUIScreenBounds = (CGRect (*)(id, SEL))method_getImplementation(m);
    method_setImplementation(m, (IMP)iOS_SwizzledUIScreenBounds);
}

static void iOS_UnswizzleUIScreenBounds(void)
{
    if (gOrigUIScreenBounds) {
        Method m = class_getInstanceMethod([UIScreen class], @selector(bounds));
        method_setImplementation(m, (IMP)gOrigUIScreenBounds);
        gOrigUIScreenBounds = nil;
    }
}

static void iOS_SwizzleSetPosition(void)
{
    if (gSwizzleActive) return;
    gSwizzleActive = YES;

    Method m = class_getInstanceMethod([CALayer class], @selector(setPosition:));
    gOrigSetPosition = (void (*)(id, SEL, CGPoint))method_getImplementation(m);
    method_setImplementation(m, (IMP)iOS_SwizzledSetPosition);

    m = class_getInstanceMethod([CALayer class], @selector(setFrame:));
    gOrigLayerSetFrame = (void (*)(id, SEL, CGRect))method_getImplementation(m);
    method_setImplementation(m, (IMP)iOS_SwizzledLayerSetFrame);

    m = class_getInstanceMethod([CALayer class], @selector(setBounds:));
    gOrigLayerSetBounds = (void (*)(id, SEL, CGRect))method_getImplementation(m);
    method_setImplementation(m, (IMP)iOS_SwizzledLayerSetBounds);

    m = class_getInstanceMethod([UIView class], @selector(setFrame:));
    gOrigViewSetFrame = (void (*)(id, SEL, CGRect))method_getImplementation(m);
    method_setImplementation(m, (IMP)iOS_SwizzledViewSetFrame);

    m = class_getInstanceMethod([UIView class], @selector(setBounds:));
    gOrigViewSetBounds = (void (*)(id, SEL, CGRect))method_getImplementation(m);
    method_setImplementation(m, (IMP)iOS_SwizzledViewSetBounds);
}

static void iOS_UnswizzleSetPosition(void)
{
    if (!gSwizzleActive) return;
    gSwizzleActive = NO;

    Method m = class_getInstanceMethod([CALayer class], @selector(setPosition:));
    method_setImplementation(m, (IMP)gOrigSetPosition);

    m = class_getInstanceMethod([CALayer class], @selector(setFrame:));
    method_setImplementation(m, (IMP)gOrigLayerSetFrame);

    m = class_getInstanceMethod([CALayer class], @selector(setBounds:));
    method_setImplementation(m, (IMP)gOrigLayerSetBounds);

    m = class_getInstanceMethod([UIView class], @selector(setFrame:));
    method_setImplementation(m, (IMP)gOrigViewSetFrame);

    m = class_getInstanceMethod([UIView class], @selector(setBounds:));
    method_setImplementation(m, (IMP)gOrigViewSetBounds);

    gOrigSetPosition = nil;
    gOrigLayerSetFrame = nil;
    gOrigLayerSetBounds = nil;
    gOrigViewSetFrame = nil;
    gOrigViewSetBounds = nil;
}

extern "C" SDL_Window* iOS_CreateWindowSafe(
    const char* title, int x, int y, int w, int h, Uint32 flags)
{
    // Install geometry swizzles BEFORE any UIKit / SDL layer manipulation.
    iOS_SwizzleSetPosition();
    iOS_SwizzleUIScreenBounds();

    // UIScreen is not reliable until the app is active on iOS 9 iPad.
    iOS_WaitUntilApplicationActive(10000);
    iOS_MeasureScreenSize(&gSanitizeFallbackSize);

    SDL_Window* result = nullptr;

    // Always prefer CreateWindowFrom: SDL_CreateWindow reads UIScreen.bounds
    // internally and can inherit the 0×0 / NaN geometry seen on iOS 9 iPad.
    iOS_WriteLog("SDL_WINDOW_INIT", "CreateWindowFrom bootstrap");
    result = iOS_TryCreateWindowFromUIKit();

    if (!result) {
        iOS_WriteLog("SDL_WINDOW_INIT", "CreateWindowFrom failed — SDL_CreateWindow fallback");
        @try {
            // Override w/h with measured screen size before creating the
            // SDL window, so the internal UIKit view gets a valid initial
            // frame and its CAEAGLLayer has non-zero dimensions.
            {
                CGSize cz;
                if (iOS_MeasureScreenSize(&cz) && iOS_SizeIsValid(cz)) {
                    w = (int)cz.width;
                    h = (int)cz.height;
                }
            }
            result = SDL_CreateWindow(title, x, y, w, h, flags);
        }
        @catch (NSException* ex) {
            iOS_WriteLog("SDL_CREATE_WINDOW_EXCEPTION",
                ex.reason.UTF8String ?: "unknown");
            iOS_UnswizzleSetPosition();
            return nullptr;
        }

        if (!result)
            iOS_WriteLog("SDL_CREATE_WINDOW_FAIL", SDL_GetError() ?: "null");

        // CreateWindowFrom failed and SDL_CreateWindow may have created a
        // 0×0 window if UIScreen.bounds was still {0,0}.  Force a real
        // UIWindow with the hardcoded screen size so that
        // iOS_FindActiveWindow / iOS_WaitForWindowLayout have something
        // to work with, and the EAGL context can be created.
        if (result) {
            UIWindow* sdlUIWin = iOS_GetSDLUIWindow(result);
            if (!sdlUIWin || !iOS_SizeIsValid(sdlUIWin.bounds.size) || !iOS_SizeIsValid(sdlUIWin.frame.size)) {
                CGSize fbSize;
                iOS_MeasureScreenSize(&fbSize);
                if (iOS_SizeIsValid(fbSize)) {
                    // Landscape: ensure width > height
                    if (fbSize.width < fbSize.height) {
                        CGFloat t = fbSize.width;
                        fbSize.width = fbSize.height;
                        fbSize.height = t;
                    }
                    CGRect fbFrame = CGRectMake(0, 0, fbSize.width, fbSize.height);

                    gForcedUIWindow = [[UIWindow alloc] initWithFrame:fbFrame];
                    UIViewController* fbVC = [[UIViewController alloc] init];
                    fbVC.view.frame = fbFrame;
                    gForcedUIWindow.rootViewController = fbVC;
                    [gForcedUIWindow makeKeyAndVisible];
                    [gForcedUIWindow layoutIfNeeded];

                    // Also force the SDL window's internal UIWindow frame
                    if (sdlUIWin) {
                        sdlUIWin.frame = fbFrame;
                        [sdlUIWin makeKeyAndVisible];
                        [sdlUIWin layoutIfNeeded];
                    }

                    SDL_SetWindowSize(result, (int)fbSize.width, (int)fbSize.height);

                    char dbg[128];
                    snprintf(dbg, sizeof(dbg), "forced UIWindow %.0fx%.0f",
                        (double)fbSize.width, (double)fbSize.height);
                    iOS_WriteLog("SDL_FORCED_WINDOW", dbg);
                }
            } else {
                iOS_WriteLog("SDL_WINDOW_SKIP_FORCE", "SDL window is already valid; skipping forcing helper window");
            }
        }
    }

    if (result) {
        UIWindow* kw = iOS_FindActiveWindow(result);
        char dbg[256];
        char kwBuf[48], scrBuf[48];
        iOS_LogSize(kwBuf, sizeof(kwBuf), "keyWin",
            kw ? kw.bounds.size : CGSizeZero);
        iOS_LogSize(scrBuf, sizeof(scrBuf), "screen",
            [UIScreen mainScreen].bounds.size);
        snprintf(dbg, sizeof(dbg), "win=%p %s %s", (void*)result, kwBuf, scrBuf);
        iOS_WriteLog("SDL_WINDOW_OK", dbg);

        const bool layoutReady = iOS_WaitForWindowLayout(result, 3000);
        kw = iOS_FindActiveWindow(result);
        iOS_LogSize(kwBuf, sizeof(kwBuf), "keyWin",
            kw ? kw.bounds.size : CGSizeZero);
        iOS_LogSize(scrBuf, sizeof(scrBuf), "screen",
            [UIScreen mainScreen].bounds.size);
        snprintf(dbg, sizeof(dbg), "layout=%s win=%p %s %s",
            layoutReady ? "OK" : "TIMEOUT", (void*)result, kwBuf, scrBuf);
        iOS_WriteLog("SDL_WINDOW_LAYOUT", dbg);
    }

    return result;
}


/// Recursively search a view's subviews for one whose layer is a CAEAGLLayer.
static UIView* iOS_FindEAGLViewRecursive(UIView* view)
{
    if ([view.layer isKindOfClass:[CAEAGLLayer class]])
        return view;
    for (UIView* sv in view.subviews) {
        UIView* found = iOS_FindEAGLViewRecursive(sv);
        if (found) return found;
    }
    return nil;
}

/// Safe wrapper around SDL_GL_CreateContext for iOS.
///
/// Strategy: SDL_GetWindowWMInfo always returns false in this SDL port, so
/// we cannot access the SDL_uikitview through the normal API.  Instead:
///   1. Pump the run loop to let UIKit settle.
///   2. Force all UIWindows to valid frames.
///   3. Recursively search ALL windows for a view whose layer is a CAEAGLLayer
///      (the SDL_uikitview, if one exists).
///   4. If found, force its frame/bounds, then try SDL_GL_CreateContext.
///   5. If SDL fails (or no CAEAGLLayer exists — e.g. SDL_CreateWindowFrom
///      path), create a UIView subclass at runtime with +layerClass returning
///      [CAEAGLLayer class], add it to the window hierarchy, and create our
///      own EAGLContext from it.
///   6. Set the context as current; return it as an SDL_GLContext.
///
/// Returns the context, or nullptr on failure.
// Screen framebuffer and renderbuffer created by our custom EAGLContext path.
// Defined here (file scope) so they are accessible to both
// iOS_CreateGLContextSafe (which creates them) and iOS_SwapWindow / iOS_GetScreenFramebuffer.
static GLuint gScreenRenderbuffer = 0;
static GLuint gScreenFramebuffer = 0;

extern "C" SDL_GLContext iOS_CreateGLContextSafe(SDL_Window* window)
{
    @try {
        // Try direct SDL creation first
        SDL_GLContext directCtx = SDL_GL_CreateContext(window);
        if (directCtx) {
            iOS_WriteLog("SDL_GL_CREATECONTEXT", "SDL_GL_CreateContext succeeded directly!");
            iOS_UnswizzleSetPosition();
            return directCtx;
        }
        // Ensure swizzle is active
        if (!gSwizzleActive)
            iOS_SwizzleSetPosition();

        UIWindow* kw = iOS_FindActiveWindow(window);
        NSArray<UIWindow*>* allWins = [UIApplication sharedApplication].windows;

        if (!iOS_WaitForWindowLayout(window, 500)) {
            iOS_SyncWindowToScreen(window, kw);
            iOS_PumpRunLoopMs(50);
            kw = iOS_FindActiveWindow(window);
        }

        // Log current state so we can track what changed
        {
            char buf[320];
            UIWindow* logWin = kw ?: (allWins.count > 0 ? allWins[0] : nil);
            if (logWin) {
                const char* orStr = "?";
                UIInterfaceOrientation orientVal = [UIApplication sharedApplication].statusBarOrientation;
                if (orientVal == UIInterfaceOrientationLandscapeLeft)  orStr = "LL";
                else if (orientVal == UIInterfaceOrientationLandscapeRight) orStr = "LR";
                else if (orientVal == UIInterfaceOrientationPortrait)  orStr = "P";
                else if (orientVal == UIInterfaceOrientationPortraitUpsideDown) orStr = "PD";

                char bndBuf[48], frmBuf[64], scrBuf[48];
                iOS_LogSize(bndBuf, sizeof(bndBuf), "bounds", logWin.bounds.size);
                if (isnan(logWin.frame.size.height)) {
                    snprintf(frmBuf, sizeof(frmBuf), "frame=(%.0f,%.0f,%.0f,nan)",
                        logWin.frame.origin.x, logWin.frame.origin.y, logWin.frame.size.width);
                } else {
                    snprintf(frmBuf, sizeof(frmBuf), "frame=(%.0f,%.0f,%.0f,%.0f)",
                        logWin.frame.origin.x, logWin.frame.origin.y,
                        logWin.frame.size.width, logWin.frame.size.height);
                }
                iOS_LogSize(scrBuf, sizeof(scrBuf), "screen",
                    [UIScreen mainScreen].bounds.size);

                snprintf(buf, sizeof(buf), "GL %s %s %s or=%s",
                    bndBuf, frmBuf, scrBuf, orStr);
                iOS_WriteLog("SDL_GL_DEBUG", buf);
            } else {
                iOS_WriteLog("SDL_GL_DEBUG", "no window found");
            }
        }

        // ------------------------------------------------------------------
        // Step 1: Force all UIWindows to valid frames.
        // ------------------------------------------------------------------
        CGSize fb;
        iOS_MeasureScreenSize(&fb);
        if (!iOS_SizeIsValid(fb))
            fb = CGSizeMake(1024, 768);
        if (fb.width < fb.height) {
            CGFloat t = fb.width; fb.width = fb.height; fb.height = t;
        }
        const CGRect fbFrame = CGRectMake(0, 0, fb.width, fb.height);

        for (UIWindow* win in [UIApplication sharedApplication].windows) {
            if (!iOS_SizeIsValid(win.bounds.size) || !iOS_SizeIsValid(win.frame.size)) {
                win.frame = fbFrame;
                [win makeKeyAndVisible];
                [win layoutIfNeeded];
            }
            UIView* rv = win.rootViewController.view;
            if (rv && (!iOS_SizeIsValid(rv.bounds.size) || !iOS_SizeIsValid(rv.frame.size))) {
                rv.frame = fbFrame;
                [rv setNeedsLayout];
                [rv layoutIfNeeded];
            }
        }

        // Spin the run loop so CoreAnimation commits layout.
        iOS_PumpRunLoopMs(50);

        // ------------------------------------------------------------------
        // Step 2: Search ALL windows recursively for a view whose layer IS
        // a CAEAGLLayer.  This is the SDL_uikitview (if SDL_CreateWindow was
        // used) or our custom view (if we've already created one).
        // ------------------------------------------------------------------
        UIView* eaglView = nil;
        {
            for (UIWindow* win in [UIApplication sharedApplication].windows) {
                eaglView = iOS_FindEAGLViewRecursive(win);
                if (eaglView) break;
                if (win.rootViewController.view) {
                    eaglView = iOS_FindEAGLViewRecursive(win.rootViewController.view);
                    if (eaglView) break;
                }
            }
        }

        // ------------------------------------------------------------------
        // Step 3: If no CAEAGLLayer exists in the hierarchy, create one.
        // Create a dedicated UIWindow from UIScreen to guarantee valid bounds,
        // and disable Auto Layout so our explicit frame is respected.
        // ------------------------------------------------------------------
        if (!eaglView) {
            static Class sEAGLViewClass = nil;
            if (!sEAGLViewClass) {
                sEAGLViewClass = objc_allocateClassPair([UIView class], "PvZEAGLView", 0);
                if (sEAGLViewClass) {
                    IMP layerClassImp = imp_implementationWithBlock(^Class{
                        return [CAEAGLLayer class];
                    });
                    Method layerMethod = class_getClassMethod([UIView class], @selector(layerClass));
                    const char* typeEnc = method_getTypeEncoding(layerMethod);
                    class_addMethod(object_getClass(sEAGLViewClass),
                                    @selector(layerClass), layerClassImp, typeEnc);
                    objc_registerClassPair(sEAGLViewClass);
                }
            }

            if (sEAGLViewClass) {
                // Create a fresh UIWindow directly from UIScreen so it gets
                // valid bounds on iOS 9 iPad Mini 1 (A5 chip, 32-bit).
                UIScreen* mainScreen = [UIScreen mainScreen];
                CGRect screenBounds = mainScreen.bounds;
                // Ensure landscape
                if (screenBounds.size.width < screenBounds.size.height) {
                    CGFloat tmp = screenBounds.size.width;
                    screenBounds.size.width = screenBounds.size.height;
                    screenBounds.size.height = tmp;
                }
                if (!iOS_SizeIsValid(screenBounds.size))
                    screenBounds = CGRectMake(0, 0, fb.width, fb.height);

                UIWindow* eaglWindow = [[UIWindow alloc] initWithFrame:screenBounds];
                UIViewController* eaglVC = [[UIViewController alloc] init];
                eaglVC.view.frame = screenBounds;
                eaglVC.view.backgroundColor = [UIColor blackColor];
                eaglWindow.rootViewController = eaglVC;
                [eaglWindow makeKeyAndVisible];
                iOS_PumpRunLoopMs(50);

                eaglView = [[sEAGLViewClass alloc] initWithFrame:screenBounds];
                // Disable Auto Layout so our frame is not overridden
                eaglView.translatesAutoresizingMaskIntoConstraints = YES;
                eaglView.autoresizingMask = UIViewAutoresizingNone;
                [eaglVC.view addSubview:eaglView];
                [eaglVC.view bringSubviewToFront:eaglView];
                // Let UIKit commit layout
                [eaglVC.view setNeedsLayout];
                [eaglVC.view layoutIfNeeded];

                char lbuf[128];
                snprintf(lbuf, sizeof(lbuf), "runtime CAEAGLLayer view win=%.0fx%.0f view=%.0fx%.0f",
                    (double)screenBounds.size.width, (double)screenBounds.size.height,
                    (double)eaglView.frame.size.width, (double)eaglView.frame.size.height);
                iOS_WriteLog("EAGL_VIEW_CREATED", lbuf);
            }
        }

        // ------------------------------------------------------------------
        // Step 4: Force the found/created view's frame and layer bounds,
        // then use CATransaction to commit immediately before renderbufferStorage.
        // ------------------------------------------------------------------
        CAEAGLLayer* eaglLayer = nil;
        if (eaglView) {
            // Disable autoresizing so parent layout can't stomp our frame
            eaglView.translatesAutoresizingMaskIntoConstraints = YES;
            eaglView.autoresizingMask = UIViewAutoresizingNone;

            // Set both frame (position+size in parent coords) and layer bounds
            eaglView.frame = fbFrame;

            // Force CATransaction to commit the frame immediately
            [CATransaction begin];
            [CATransaction setValue:(id)kCFBooleanTrue forKey:kCATransactionDisableActions];
            eaglView.layer.bounds = CGRectMake(0, 0, fb.width, fb.height);
            [CATransaction commit];

            [eaglView setNeedsLayout];
            [eaglView layoutIfNeeded];

            if ([eaglView.layer isKindOfClass:[CAEAGLLayer class]]) {
                eaglLayer = (CAEAGLLayer*)eaglView.layer;
                eaglLayer.opaque = YES;
                eaglLayer.drawableProperties = @{
                    kEAGLDrawablePropertyRetainedBacking: @NO,
                    kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8
                };
            }
        }

        // Let CoreAnimation commit the layer changes before querying it.
        // Wait in a loop until bounds are actually non-zero (up to 500ms).
        if (eaglLayer) {
            char lb[64];
            iOS_LogSize(lb, sizeof(lb), "layerBnd", eaglLayer.bounds.size);
            iOS_WriteLog("LAYER_BEFORE", lb);

            for (int wi = 0; wi < 10 && !iOS_SizeIsValid(eaglLayer.bounds.size); wi++) {
                iOS_PumpRunLoopMs(50);
                // Re-apply bounds if they got reset
                [CATransaction begin];
                [CATransaction setValue:(id)kCFBooleanTrue forKey:kCATransactionDisableActions];
                eaglLayer.bounds = CGRectMake(0, 0, fb.width, fb.height);
                [CATransaction commit];
            }

            iOS_LogSize(lb, sizeof(lb), "layerBnd", eaglLayer.bounds.size);
            iOS_WriteLog("LAYER_AFTER", lb);

            // If still 0x0, force it directly on the model layer
            if (!iOS_SizeIsValid(eaglLayer.bounds.size)) {
                eaglLayer.bounds = CGRectMake(0, 0, fb.width, fb.height);
                [CATransaction flush];
                iOS_PumpRunLoopMs(50);
                iOS_LogSize(lb, sizeof(lb), "layerBnd_force", eaglLayer.bounds.size);
                iOS_WriteLog("LAYER_FORCE", lb);
            }
        }

        // ------------------------------------------------------------------
        // Step 5: Try SDL_GL_CreateContext first — if we have a valid
        // CAEAGLLayer with non-zero bounds, SDL might succeed now.
        // ------------------------------------------------------------------
        SDL_GLContext ctx = nullptr;
        if (eaglLayer && iOS_SizeIsValid(eaglLayer.bounds.size)) {
            char lb[64];
            iOS_LogSize(lb, sizeof(lb), "layerBnd_final", eaglLayer.bounds.size);
            iOS_WriteLog("LAYER_FINAL", lb);

            ctx = SDL_GL_CreateContext(window);
            if (ctx) {
                iOS_WriteLog("SDL_GL_CREATECONTEXT", "SDL_GL_CreateContext succeeded after layout fix");
            }
        } else if (eaglLayer) {
            iOS_WriteLog("SDL_GL_SKIP", "layer bounds still 0x0 — skipping SDL_GL_CreateContext");
        }

        // ------------------------------------------------------------------
        // Step 6: If SDL failed, create our own EAGLContext from the layer.
        // ------------------------------------------------------------------
        if (!ctx && eaglLayer) {
            EAGLContext* eaglCtx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
            if (eaglCtx) {
                [EAGLContext setCurrentContext:eaglCtx];
                GLuint rb;
                glGenRenderbuffers(1, &rb);
                glBindRenderbuffer(GL_RENDERBUFFER, rb);
                if ([eaglCtx renderbufferStorage:GL_RENDERBUFFER fromDrawable:eaglLayer]) {
                    GLint rbW = 0, rbH = 0;
                    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &rbW);
                    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &rbH);
                    char rbb[64];
                    snprintf(rbb, sizeof(rbb), "rb=%dx%d", rbW, rbH);
                    iOS_WriteLog("GL_RB_SIZE", rbb);

                    GLuint fb = 0;
                    glGenFramebuffers(1, &fb);
                    glBindFramebuffer(GL_FRAMEBUFFER, fb);
                    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);

                    gScreenRenderbuffer = rb;
                    gScreenFramebuffer = fb;

                    ctx = (__bridge SDL_GLContext)eaglCtx;
                    iOS_WriteLog("EAGL_CUSTOM", "custom EAGLContext created OK with framebuffer");
                } else {
                    iOS_WriteLog("EAGL_CUSTOM_FAIL", "renderbufferStorage returned NO");
                }
            } else {
                iOS_WriteLog("EAGL_CUSTOM_FAIL", "EAGLContext alloc failed");
            }
        }

        if (!ctx) {
            iOS_WriteLog("CTX_FAIL", "no GL context could be created (SDL or custom)");
        }

        if (ctx) {
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


/// Defer the game entry point until after UIApplication becomes active.
/// SDL runs main() from applicationDidFinishLaunching; UIScreen.bounds on
/// iOS 9 iPad only becomes valid after applicationDidBecomeActive.
extern "C" int iOS_RunGameAfterActivation(int (*runGameFn)(int, char**), int argc, char** argv)
{
    __block int exitCode = 0;
    __block BOOL done = NO;

    iOS_WriteLog("IOS_DEFER", "queue run_game after launch returns");

    // Double dispatch_async: the first block runs after didFinishLaunching
    // returns; the second runs after applicationDidBecomeActive, when
    // UIScreen.bounds is valid on iOS 9 iPad.
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            iOS_WriteLog("IOS_DEFER", "run_game starting (post-activation)");
            exitCode = runGameFn(argc, argv);
            done = YES;
        });
    });

    while (!done) {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
    }

    return exitCode;
}


// ---------------------------------------------------------------------------
// Custom swap — called from GLInterface::Flush() on iOS instead of
// SDL_GL_SwapWindow (which would try to use window->driverdata.context
// that we never set when bypassing SDL_GL_CreateContext).
// ---------------------------------------------------------------------------

namespace Sexy {
unsigned int iOS_GetScreenFramebuffer()
{
    return gScreenFramebuffer;
}

void iOS_SwapWindow(SDL_Window* window)
{
    @autoreleasepool {
        EAGLContext* ctx = [EAGLContext currentContext];
        if (ctx) {
            if (gScreenRenderbuffer) {
                glBindRenderbuffer(GL_RENDERBUFFER, gScreenRenderbuffer);
            }
            [ctx presentRenderbuffer:GL_RENDERBUFFER];
        }
    }
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
