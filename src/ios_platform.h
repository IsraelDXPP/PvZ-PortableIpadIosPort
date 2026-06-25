#pragma once

#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Reliable Documents path (do not use getenv("HOME") on iOS). */
bool iOS_GetDocumentsPath(char* outPath, size_t outPathSize);

/* Write a line to Documents/pvz_log.txt AND NSLog. Always works,
   even before UIApplicationMain is ready. */
void iOS_WriteLogPublic(const char* tag, const char* message);

/* Blocks until the user dismisses the alert (works on iOS 9+).
   Safe to call from any thread. Always logs to pvz_log.txt first. */
void iOS_ShowBlockingAlert(const char* title, const char* message);

/* Spin-waits up to maxWaitMs ms until UIScreen.mainScreen.bounds is valid.
   Falls back to 1024x768 if it times out. */
bool iOS_WaitForValidScreenBounds(int* outW, int* outH, int maxWaitMs);

/* Safe replacement for SDL_CreateWindow on iOS.
   Wraps the call in ObjC @try/@catch so a CALayerInvalidGeometry NSException
   cannot escape into the SjLj C++ unwinder and cause __cxa_bad_cast/abort.
   Returns NULL on unrecoverable failure (caller should show an error). */
struct SDL_Window;
typedef unsigned int Uint32;
SDL_Window* iOS_CreateWindowSafe(const char* title, int x, int y, int w, int h, Uint32 flags);

/* Safe wrapper around SDL_GL_CreateContext for iOS.
   Uses ObjC @try/@catch to prevent UIKit NSExceptions from escaping.
   Returns an SDL_GLContext (void*) or nullptr on failure. */
void* iOS_CreateGLContextSafe(struct SDL_Window* window);

/* Top-level @try/@catch wrapper around the game's entry-point function.
   Catches any ObjC NSException that propagates up from the game loop
   before it reaches the C++ SjLj unwinder.  Returns entry(argc, argv)
   or 1 if an exception was caught. */
int iOS_RunWithExceptionCatch(int (*entry)(int, char**), int argc, char** argv);

#ifdef __cplusplus
}
#endif
