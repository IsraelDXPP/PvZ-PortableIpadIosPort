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
    -G Xcode

echo "--- Building ---"
cmake --build "$BUILD_DIR/game" --config "$BUILD_TYPE" -- \
    -sdk iphoneos \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_ALLOWED=NO

# Create unsigned IPA
APP_PATH=$(find "$BUILD_DIR/game" -name "pvz-portable.app" -path "*${BUILD_TYPE}*" | head -1)
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
