#!/bin/bash
#
# submit_mas.sh — archive, sign, wrap in .pkg, and upload Espresso Macchiato
# to App Store Connect for Mac App Store distribution.
#
# This is the MAS counterpart to notarize.sh. The two pipelines share the same
# source code and Xcode project, but use different build configurations, signing
# certs, and wrapping formats:
#
#                     notarize.sh            submit_mas.sh (this file)
#   ------------  ---------------------  --------------------------------
#   Config         Release                ReleaseMAS
#   Cert (.app)    Developer ID App       Apple Distribution
#   Cert (.pkg)    (none — ships .zip)    Mac Installer Distribution
#   Entitlements   (none)                 Espresso/Espresso-MAS.entitlements
#                                          (App Sandbox ON)
#   Provisioning   (none)                 Mac App Store profile
#   Delivers to    Apple notary service   App Store Connect
#   Ships as       Notarized .zip on      Mac App Store listing
#                  GitHub release
#
# Prereqs (one-time, ALL currently pending boss/ASC setup):
#
#   1. All three certs installed in login keychain:
#        - Developer ID Application: Andrea Grandi (3UFB423D7P)   ✅ have
#        - Apple Distribution: Andrea Grandi (3UFB423D7P)         ✅ have
#        - Mac Installer Distribution: Andrea Grandi (3UFB423D7P) ⏳ pending
#
#   2. Bundle ID "com.nervoussystems.espressomacchiato" registered in
#      https://developer.apple.com/account/resources/identifiers
#      (Admin/App Manager role required)                          ⏳ pending
#
#   3. Mac App Store provisioning profile for that bundle ID, bound to the
#      Apple Distribution cert, downloaded and installed. Embed it by
#      setting PROVISIONING_PROFILE_SPECIFIER in the Xcode project (or let
#      Xcode auto-resolve if the profile is on disk at
#      ~/Library/MobileDevice/Provisioning\ Profiles/)             ⏳ pending
#
#   4. App record created in App Store Connect:
#      https://appstoreconnect.apple.com/apps → + → New App
#      Platform: macOS, Bundle ID: com.nervoussystems.espressomacchiato,
#      SKU: any string, Primary Language: English                  ⏳ pending
#
#   5. App-specific password stored in the login keychain as the generic
#      item "espresso-altool" — the altool calls below read it via
#      @keychain:espresso-altool. NOTE: this is separate from the
#      notarytool profile "espresso-notary" (altool cannot read
#      notarytool profiles). Store it once with:
#        xcrun altool --store-password-in-keychain-item "espresso-altool" \
#          --username "<your apple id email>" \
#          --password "<app-specific-password>"                     ✅ have
#
set -euo pipefail

source "$(dirname "$0")/build-common.sh"

CONFIG="ReleaseMAS"
# Apple ID used for altool validate/upload; override per-machine with
#   APPLE_ID=someone@example.com ./submit_mas.sh
APPLE_ID="${APPLE_ID:-luca@gibelli.it}"
ALTOOL_KEYCHAIN_ITEM="espresso-altool"
# Bundle ID comes from Info.plist (the single source of truth) so the
# provisioning-profile mapping below can't drift from the app.
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PROJECT_ROOT/Espresso/Info.plist")

BUILD_DIR="$PROJECT_ROOT/build-mas"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
PKG_PATH="$EXPORT_PATH/$APP_NAME.pkg"
EXPORT_OPTIONS="$BUILD_DIR/exportOptions.plist"

# Sanity checks — each of these is a specific prereq; fail early with guidance.
command -v xcodebuild >/dev/null || die "xcodebuild not on PATH"

security find-identity -v -p basic 2>/dev/null | \
  grep -q "Apple Distribution: .*($TEAM_ID)" || \
  die "Missing 'Apple Distribution' identity for team $TEAM_ID.
       Boss needs to upload NervousSystems_AppleDistribution.certSigningRequest
       at https://developer.apple.com/account/resources/certificates"

security find-identity -v -p basic 2>/dev/null | \
  grep -q "3rd Party Mac Developer Installer\|Mac Installer Distribution" || \
  die "Missing 'Mac Installer Distribution' identity for team $TEAM_ID.
       Boss needs to upload NervousSystems_MacInstallerDistribution.certSigningRequest
       at https://developer.apple.com/account/resources/certificates → Mac Installer Distribution"

security find-generic-password -s "$ALTOOL_KEYCHAIN_ITEM" >/dev/null 2>&1 || \
  security find-generic-password -l "$ALTOOL_KEYCHAIN_ITEM" >/dev/null 2>&1 || \
  die "Keychain item '$ALTOOL_KEYCHAIN_ITEM' missing — altool auth will fail.
       Store it: xcrun altool --store-password-in-keychain-item '$ALTOOL_KEYCHAIN_ITEM' \\
                   --username '$APPLE_ID' --password '<app-specific-password>'"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

say "1/5  Archive ($CONFIG, sandbox on, Apple Distribution signing)"
do_archive "$CONFIG" "$ARCHIVE_PATH"

say "2/5  Write MAS export options"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>export</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Apple Distribution</string>
    <key>installerSigningCertificate</key>
    <string>3rd Party Mac Developer Installer</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>$BUNDLE_ID</key>
        <string>Espresso Macchiato MAS</string>
    </dict>
</dict>
</plist>
PLIST

say "3/5  Export .pkg from archive (signed with Mac Installer Distribution)"
do_export "$ARCHIVE_PATH" "$EXPORT_PATH" "$EXPORT_OPTIONS"

[ -f "$PKG_PATH" ] || die "Exported .pkg not found at $PKG_PATH"

say "4/5  Validate .pkg against App Store Connect"
xcrun altool --validate-app \
  --type macos \
  --file "$PKG_PATH" \
  --username "$APPLE_ID" \
  --password "@keychain:$ALTOOL_KEYCHAIN_ITEM" \
  --team-id "$TEAM_ID"

say "5/5  Upload to App Store Connect"
xcrun altool --upload-app \
  --type macos \
  --file "$PKG_PATH" \
  --username "$APPLE_ID" \
  --password "@keychain:$ALTOOL_KEYCHAIN_ITEM" \
  --team-id "$TEAM_ID"

printf "\n\033[1;32m✅ UPLOADED\033[0m\n"
echo "   Now go to https://appstoreconnect.apple.com/apps → Espresso Macchiato"
echo "   and fill in metadata, screenshots, then Submit for Review."
printf "\n"
