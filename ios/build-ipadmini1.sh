#!/bin/bash
# Build PvZ-Portable for iPad mini 1 (armv7, iOS 9.0).
# Usage: ./ios/build-ipadmini1.sh [Debug|Release]
#
# Requirements:
#   - macOS with Xcode that includes the iPhoneOS9.3.sdk
#     (Xcode 7.x, or a modern Xcode with the legacy SDK injected)
#   - CMake 3.21+
#   - vcpkg (VCPKG_ROOT must be set)
#
# To inject the iOS 9.3 SDK into a modern Xcode:
#   1. Download iPhoneOS9.3.sdk from https://github.com/xybp888/iOS-SDKs
#   2. sudo cp -R iPhoneOS9.3.sdk \
#        /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/
#   3. Re-run this script.

set -euo pipefail

BUILD_TYPE="${1:-Release}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build-ios-ipadmini1"
TRIPLETS_DIR="$PROJECT_ROOT/CMake"

echo "=== PvZ-Portable iPad mini 1 Build (armv7, iOS 9.0, $BUILD_TYPE) ==="

if [ -z "${VCPKG_ROOT:-}" ]; then
    echo "Error: VCPKG_ROOT is not set. Install vcpkg and set VCPKG_ROOT."
    exit 1
fi

# Verify that the iOS 9.x SDK is available
IOS9_SDK=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)
if [ -z "$IOS9_SDK" ]; then
    echo "Error: iOS SDK not found. Install Xcode and run: xcode-select --install"
    exit 1
fi

# Try to locate the iPhoneOS9.x SDK specifically
XCODE_SDKS_DIR="$(dirname "$IOS9_SDK")"
IOS9_SPECIFIC_SDK=$(ls -d "$XCODE_SDKS_DIR/iPhoneOS9"*.sdk 2>/dev/null | sort -V | tail -1 || true)

if [ -n "$IOS9_SPECIFIC_SDK" ]; then
    echo "Found iOS 9 SDK at: $IOS9_SPECIFIC_SDK"
    SYSROOT_ARG="-DCMAKE_OSX_SYSROOT=$IOS9_SPECIFIC_SDK"
    DEPLOY_TARGET="9.0"
else
    echo "WARNING: iOS 9 SDK not found in $XCODE_SDKS_DIR"
    echo "         Falling back to default iphoneos SDK with iOS 12.0 deployment target."
    echo "         The resulting binary will NOT run on iPad mini 1 (max iOS 9.3.5)."
    echo ""
    echo "To fix this, inject the iOS 9.3 SDK:"
    echo "  1. Download: https://github.com/xybp888/iOS-SDKs"
    echo "  2. sudo cp -R iPhoneOS9.3.sdk $XCODE_SDKS_DIR/"
    SYSROOT_ARG="-DCMAKE_OSX_SYSROOT=iphoneos"
    DEPLOY_TARGET="12.0"
fi

mkdir -p "$BUILD_DIR"

# Locate Xcode 14.x (or any Xcode) with armv7 compiler-rt for SjLj support
CLANG_RT_ARMV7=""
# Search Xcode installations for armv7-compatible libclang_rt.ios.a
for XCODE_VER in 14.3.1 14.3 14.2 14.1 14; do
    CLANG_RT=$(find "/Applications/Xcode_${XCODE_VER}.app" -name "libclang_rt.ios.a" 2>/dev/null | head -1)
    if [ -n "$CLANG_RT" ]; then
        echo "Found libclang_rt.ios.a at: $CLANG_RT"
        EXTRACTED="/tmp/libclang_rt_armv7.a"
        # Extract armv7 slice (the only slice that matters for iPad mini 1)
        lipo -extract armv7 "$CLANG_RT" -output "$EXTRACTED" 2>/dev/null || cp "$CLANG_RT" "$EXTRACTED"
        CLANG_RT_ARMV7="$EXTRACTED"
        echo "Extracted armv7 SjLj runtime to: $EXTRACTED"
        break
    fi
done
if [ -z "$CLANG_RT_ARMV7" ]; then
    echo "WARNING: Could not find Xcode with armv7 libclang_rt.ios.a"
    echo "         SjLj exception symbols may be missing at runtime."
    echo "         Install Xcode 14.x to fix this, or extract libclang_rt.ios.a manually."
fi

echo "--- Configuring CMake for armv7 iOS ---"
cmake -B "$BUILD_DIR/game" -S "$PROJECT_ROOT" \
    -DCMAKE_TOOLCHAIN_FILE="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" \
    -DVCPKG_TARGET_TRIPLET=armv7-ios \
    -DVCPKG_OVERLAY_TRIPLETS="$TRIPLETS_DIR" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY_TARGET" \
    -DCMAKE_OSX_ARCHITECTURES=armv7 \
    $SYSROOT_ARG \
    -DIOS_IPADMINI1=ON \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,-ld_classic -Wl,-w${CLANG_RT_ARMV7:+ $CLANG_RT_ARMV7}" \
    -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-ld_classic -Wl,-w" \
    -G Ninja

echo "--- Building ---"
cmake --build "$BUILD_DIR/game" --config "$BUILD_TYPE"

# Create unsigned IPA
APP_PATH=$(find "$BUILD_DIR" -name "pvz-portable.app" -type d | head -1)
if [ -z "$APP_PATH" ]; then
    echo "Warning: .app bundle not found, skipping IPA creation"
else
    IPA_DIR="$BUILD_DIR/ipa"
    mkdir -p "$IPA_DIR/Payload"
    cp -R "$APP_PATH" "$IPA_DIR/Payload/"
    cd "$IPA_DIR"
    zip -r -y "$BUILD_DIR/pvz-portable-ipadmini1.ipa" Payload/
    rm -rf "$IPA_DIR"
    echo ""
    echo "IPA created: $BUILD_DIR/pvz-portable-ipadmini1.ipa"
    echo "Install with: AltStore, Sideloadly, or via 'ideviceinstaller -i'"
fi

echo "=== iPad mini 1 Build Complete ==="
