#!/bin/bash
#
# build.sh — quick local build with plain swiftc, no Xcode required.
# (The release pipelines in notarize.sh / submit_mas.sh use xcodebuild.)
#
set -e

source "$(dirname "$0")/build-common.sh"

DEPLOYMENT_TARGET="12.0"
BUILD_DIR="${PROJECT_ROOT}/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "🔨 Building ${APP_NAME}..."

# Clean previous build
rm -rf "${BUILD_DIR}"

# Create .app bundle structure
mkdir -p "${MACOS}"
mkdir -p "${RESOURCES}"

# Compile Swift source
echo "  Compiling Swift..."
swiftc \
    -O \
    -whole-module-optimization \
    -target "arm64-apple-macosx${DEPLOYMENT_TARGET}" \
    -sdk $(xcrun --show-sdk-path) \
    -import-objc-header /dev/null \
    -o "${MACOS}/${APP_NAME}" \
    "${PROJECT_ROOT}/Espresso/main.swift" \
    2>&1

# If you're on Intel Mac, also compile for x86_64 and lipo them:
# swiftc -O -target "x86_64-apple-macosx${DEPLOYMENT_TARGET}" -sdk $(xcrun --show-sdk-path) \
#     -o "${MACOS}/${APP_NAME}-x86" "${PROJECT_ROOT}/Espresso/main.swift"
# lipo -create "${MACOS}/${APP_NAME}" "${MACOS}/${APP_NAME}-x86" \
#     -output "${MACOS}/${APP_NAME}-universal"
# mv "${MACOS}/${APP_NAME}-universal" "${MACOS}/${APP_NAME}"
# rm "${MACOS}/${APP_NAME}-x86"

# Copy Info.plist, expanding the build settings Xcode would normally
# substitute (LSMinimumSystemVersion references MACOSX_DEPLOYMENT_TARGET).
sed "s/\$(MACOSX_DEPLOYMENT_TARGET)/${DEPLOYMENT_TARGET}/g" \
    "${PROJECT_ROOT}/Espresso/Info.plist" > "${CONTENTS}/Info.plist"

# Generate a simple app icon (coffee cup) using Python if available
if command -v python3 &>/dev/null; then
    echo "  Generating app icon..."
    python3 "${PROJECT_ROOT}/generate_icon.py" "${RESOURCES}/AppIcon.icns" 2>/dev/null || true
fi

echo ""
echo "✅ Build complete: ${APP_BUNDLE}"
echo ""
echo "To install:"
echo "  cp -r ${APP_BUNDLE} /Applications/"
echo ""
echo "To run directly:"
echo "  open ${APP_BUNDLE}"
echo ""
echo "NOTE: On first launch, macOS may ask you to allow the app."
echo "      Go to System Settings → Privacy & Security → Open Anyway"
