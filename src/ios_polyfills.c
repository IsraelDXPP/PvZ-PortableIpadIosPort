#include <stdint.h>

#ifdef __arm__

// Simple software division and modulo for ARMv7 since Xcode 15 dropped them from libclang_rt

__attribute__((weak)) uint32_t __udivsi3(uint32_t n, uint32_t d) {
    if (d == 0) return 0;
    uint32_t q = 0;
    uint32_t r = 0;
    for (int i = 31; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1);
        if (r >= d) {
            r -= d;
            q |= (1U << i);
        }
    }
    return q;
}

__attribute__((weak)) uint32_t __umodsi3(uint32_t n, uint32_t d) {
    if (d == 0) return 0;
    uint32_t r = 0;
    for (int i = 31; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1);
        if (r >= d) {
            r -= d;
        }
    }
    return r;
}

__attribute__((weak)) int32_t __modsi3(int32_t a, int32_t b) {
    int32_t rem = __umodsi3(a < 0 ? -a : a, b < 0 ? -b : b);
    return a < 0 ? -rem : rem;
}

__attribute__((weak)) uint64_t __udivdi3(uint64_t n, uint64_t d) {
    if (d == 0) return 0;
    uint64_t q = 0;
    uint64_t r = 0;
    for (int i = 63; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1);
        if (r >= d) {
            r -= d;
            q |= (1ULL << i);
        }
    }
    return q;
}

__attribute__((weak)) uint64_t __umoddi3(uint64_t n, uint64_t d) {
    if (d == 0) return 0;
    uint64_t r = 0;
    for (int i = 63; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1);
        if (r >= d) {
            r -= d;
        }
    }
    return r;
}

__attribute__((weak)) int64_t __moddi3(int64_t a, int64_t b) {
    int64_t rem = __umoddi3(a < 0 ? -a : a, b < 0 ? -b : b);
    return a < 0 ? -rem : rem;
}

#endif // __arm__

#ifdef __APPLE__
// __availability_version_check was added in iOS 13 for __builtin_available().
// Since we are targeting iOS 9/10, we should return 0 to indicate the features are NOT available.
__attribute__((weak)) uint32_t __availability_version_check(uint32_t count, void *versions) {
    return 0;
}
#endif
