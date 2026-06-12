#!/bin/bash
#
# release-dmg.sh — build, Developer-ID-sign, notarize, staple, and package
# Espresso Macchiato as a notarized .dmg for direct download (outside the Mac
# App Store). Runs locally, or in CI via .github/workflows/release-signed.yml.
#
# Uses the REAL "Developer ID Application" cert (same as notarize.sh) — NOT a
# self-signed/ad-hoc identity. The app, then the .dmg, are each notarized +
# stapled, so a freshly downloaded .dmg opens with no Gatekeeper warning offline.
#
# Notarization auth (picked automatically):
#   - App Store Connect API key  → set APPLE_API_KEY_PATH + APPLE_API_KEY_ID +
#     APPLE_API_ISSUER  (the CI path; no stored profile needed)
#   - else a stored keychain profile → KEYCHAIN_PROFILE (default "espresso-notary",
#     the local path; see notarize.sh for how to create it)
#
# Output:
#   build-notarize/Espresso-<version>.dmg
#
set -euo pipefail

source "$(dirname "$0")/build-common.sh"
require_team_id

CONFIG="Release"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-espresso-notary}"
# Full Developer ID identity; falls back to a prefix match (works when exactly
# one such cert is in the keychain). CI injects the exact string via the
# MACOS_SIGNING_IDENTITY repo Variable.
SIGN_ID="${MACOS_SIGNING_IDENTITY:-Developer ID Application}"

BUILD_DIR="$PROJECT_ROOT/build-notarize"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/$APP_NAME.app"
EXPORT_OPTIONS="$BUILD_DIR/exportOptions.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_ROOT/Espresso/Info.plist")
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

command -v xcodebuild >/dev/null || die "xcodebuild not on PATH"
security find-identity -v -p basic 2>/dev/null | \
  grep -q "Developer ID Application: .*($TEAM_ID)" || \
  die "No 'Developer ID Application' identity for team $TEAM_ID found in keychain"

# notary_submit <file> — submit to Apple's notary service with whichever
# credentials are configured (API key preferred, else keychain profile).
notary_submit() {
  if [ -n "${APPLE_API_KEY_PATH:-}" ] && [ -n "${APPLE_API_KEY_ID:-}" ] && [ -n "${APPLE_API_ISSUER:-}" ]; then
    xcrun notarytool submit "$1" \
      --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER" \
      --wait --timeout 20m
  else
    xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" --output-format json >/dev/null 2>&1 || \
      die "no API key (APPLE_API_*) set and keychain profile '$KEYCHAIN_PROFILE' is missing/invalid"
    xcrun notarytool submit "$1" --keychain-profile "$KEYCHAIN_PROFILE" --wait --timeout 20m
  fi
}

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

say "1/6  Archive ($CONFIG)"
do_archive "$CONFIG" "$ARCHIVE_PATH"
[ -d "$ARCHIVE_PATH" ] || die "archive not produced at $ARCHIVE_PATH"

# xcodebuild -exportArchive segfaults on the CI runners (an Xcode/IDEDistribution
# bug), so skip it: the archive already contains the Release-config (Developer
# ID, manual) signed .app. Copy it out and re-sign with the hardened runtime +
# a secure timestamp (both required for notarization).
say "2/6  Extract .app from archive + Developer-ID re-sign (hardened runtime)"
ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
[ -d "$ARCHIVED_APP" ] || die "app not found in archive at $ARCHIVED_APP"
mkdir -p "$EXPORT_PATH"
rm -rf "$APP_PATH"
cp -R "$ARCHIVED_APP" "$EXPORT_PATH/"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP_PATH"
codesign --verify --strict --verbose=2 "$APP_PATH"

say "3/6  Notarize + staple the .app"
ZIP_TMP="$BUILD_DIR/$APP_NAME-app.zip"
(cd "$EXPORT_PATH" && ditto -c -k --keepParent "$APP_NAME.app" "$ZIP_TMP")
notary_submit "$ZIP_TMP"
xcrun stapler staple "$APP_PATH"
rm -f "$ZIP_TMP"

say "4/6  Build .dmg (stapled app + drag-to-Applications)"
DMG_STAGE="$BUILD_DIR/dmg-stage"
rm -rf "$DMG_STAGE"; mkdir -p "$DMG_STAGE"
cp -R "$APP_PATH" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_PATH"

say "5/6  Sign + notarize + staple the .dmg"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG_PATH"
notary_submit "$DMG_PATH"
xcrun stapler staple "$DMG_PATH"

say "6/6  Verify"
xcrun stapler validate "$DMG_PATH"
spctl -a -vvv -t open --context context:primary-signature "$DMG_PATH" 2>&1 || true

printf "\n\033[1;32m✅ DONE\033[0m\n"
echo "   Notarized DMG: $DMG_PATH"
printf "\n"
