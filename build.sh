#!/bin/bash
set -e

APP_NAME="Espresso"
BUILD_DIR="build"
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
    -target arm64-apple-macosx12.0 \
    -sdk $(xcrun --show-sdk-path) \
    -import-objc-header /dev/null \
    -o "${MACOS}/${APP_NAME}" \
    Espresso.swift \
    2>&1

# If you're on Intel Mac, also compile for x86_64 and lipo them:
# swiftc -O -target x86_64-apple-macosx12.0 -sdk $(xcrun --show-sdk-path) \
#     -o "${MACOS}/${APP_NAME}-x86" Espresso.swift
# lipo -create "${MACOS}/${APP_NAME}" "${MACOS}/${APP_NAME}-x86" \
#     -output "${MACOS}/${APP_NAME}-universal"
# mv "${MACOS}/${APP_NAME}-universal" "${MACOS}/${APP_NAME}"
# rm "${MACOS}/${APP_NAME}-x86"

# Copy Info.plist
cp Info.plist "${CONTENTS}/Info.plist"

# Generate a simple app icon (coffee cup) using Python if available
if command -v python3 &>/dev/null; then
    echo "  Generating app icon..."
    python3 generate_icon.py "${RESOURCES}/AppIcon.icns" 2>/dev/null || true
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
