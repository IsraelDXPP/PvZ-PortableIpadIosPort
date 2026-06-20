# vcpkg triplet: armv7-ios
# Targets 32-bit ARMv7 iOS devices (iPad mini 1 / A5, iPhone 5, etc.)
# Requires iOS SDK 9.x or a compatible legacy SDK injected into Xcode.

set(VCPKG_TARGET_ARCHITECTURE arm)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)

set(VCPKG_CMAKE_SYSTEM_NAME iOS)

# iOS 9.0 matches the maximum iOS version supported by iPad mini 1 (A5 chip)
set(VCPKG_CMAKE_SYSTEM_VERSION 9.0)

set(VCPKG_OSX_ARCHITECTURES armv7)
