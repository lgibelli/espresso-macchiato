#!/bin/bash
#
# notarize.sh — build, sign, notarize, staple, and zip Espresso Macchiato
# for Developer ID distribution (outside the Mac App Store).
#
# Prereqs (one-time):
#   1. Developer ID Application certificate installed in login keychain.
#   2. Apple WWDR G3 intermediate installed (for Apple Distribution chain).
#   3. Credentials stored via:
#        xcrun notarytool store-credentials "espresso-notary" \
#          --apple-id "<your apple id email>" \
#          --team-id  "3UFB423D7P" \
#          --password "<app-specific-password>"
#
# Usage:
#   ./notarize.sh
#
# Output:
#   build-notarize/Espresso-<version>.zip   ← signed, notarized, stapled; distribute this
#
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
SCHEME="Espresso"
CONFIG="Release"
APP_NAME="Espresso"
TEAM_ID="3UFB423D7P"
KEYCHAIN_PROFILE="espresso-notary"

BUILD_DIR="$PROJECT_ROOT/build-notarize"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/$APP_NAME.app"
EXPORT_OPTIONS="$BUILD_DIR/exportOptions.plist"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_ROOT/Espresso/Info.plist")
ZIP_NAME="$APP_NAME-$VERSION.zip"
ZIP_PATH="$BUILD_DIR/$ZIP_NAME"

say() { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
die() { printf "\n\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }

# Sanity checks
command -v xcodebuild >/dev/null || die "xcodebuild not on PATH"
security find-identity -v -p basic 2>/dev/null | \
  grep -q "Developer ID Application: .*($TEAM_ID)" || \
  die "No 'Developer ID Application' identity for team $TEAM_ID found in keychain"

xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" --output-format json >/dev/null 2>&1 || \
  die "notarytool keychain profile '$KEYCHAIN_PROFILE' missing or invalid.
       Run: xcrun notarytool store-credentials '$KEYCHAIN_PROFILE' \\
              --apple-id '<your apple id>' --team-id '$TEAM_ID' --password '<app-specific-password>'"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

say "1/6  Archive ($CONFIG)"
xcodebuild archive \
  -project "$PROJECT_ROOT/Espresso.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS" \
  | grep -E "^(\*\*|error:|warning:)" || true

say "2/6  Write export options"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
PLIST

say "3/6  Export .app from archive"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  | grep -E "^(\*\*|error:|warning:)" || true

[ -d "$APP_PATH" ] || die "Exported .app not found at $APP_PATH"

say "4/6  Zip for notarization submission"
(cd "$EXPORT_PATH" && ditto -c -k --keepParent "$APP_NAME.app" "$ZIP_PATH")

say "5/6  Submit to Apple notary service (this takes 1–5 min)"
xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait \
  --timeout 15m

say "6/6  Staple ticket to .app + re-zip"
xcrun stapler staple "$APP_PATH"
rm -f "$ZIP_PATH"
(cd "$EXPORT_PATH" && ditto -c -k --keepParent "$APP_NAME.app" "$ZIP_PATH")

say "Final verification"
xcrun stapler validate "$APP_PATH"
spctl --assess --verbose=4 --type execute "$APP_PATH" 2>&1 || true

printf "\n\033[1;32m✅ DONE\033[0m\n"
echo "   Distributable zip: $ZIP_PATH"
echo "   Stapled .app:      $APP_PATH"
printf "\n"
