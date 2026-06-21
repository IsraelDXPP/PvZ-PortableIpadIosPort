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

#ifdef __cplusplus
}
#endif
