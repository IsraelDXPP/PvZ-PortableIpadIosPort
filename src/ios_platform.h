#pragma once

#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Reliable Documents path (do not use getenv("HOME") on iOS). */
bool iOS_GetDocumentsPath(char* outPath, size_t outPathSize);

/* Blocks until the user dismisses the alert (works on iOS 9+). */
void iOS_ShowBlockingAlert(const char* title, const char* message);

bool iOS_WaitForValidScreenBounds(int* outW, int* outH, int maxWaitMs);

#ifdef __cplusplus
}
#endif
