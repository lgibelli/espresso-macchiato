#!/bin/bash
#
# submit_mas.sh — build Espresso Macchiato for the Mac App Store, sign it,
# wrap it in an installer package, have App Store Connect validate it, and
# with --upload send it there as a new build. Runs locally, or in CI via
# .github/workflows/release-signed.yml (the app-store job).
#
#   ./submit_mas.sh             build-mas/Espresso-<version>-<build>.pkg, validated
#   ./submit_mas.sh --upload    and upload it, as a new build of the app
#   BUILD_NUMBER=10003.1 ./submit_mas.sh --upload
#                               another upload of the same version
#
# This is the MAS counterpart to release-dmg.sh. The two pipelines share the
# same source code and Xcode project, but use different build configurations,
# signing certs, and wrapping formats:
#
#                     release-dmg.sh         submit_mas.sh (this file)
#   ------------  ---------------------  --------------------------------
#   Config         Release                ReleaseMAS
#   Cert (.app)    Developer ID App       Apple Distribution
#   Cert (.pkg)    (none — ships .dmg)    Mac Installer Distribution
#   Entitlements   (none)                 Espresso/Espresso-MAS.entitlements
#                                          (App Sandbox ON)
#   Provisioning   (none)                 Mac App Store profile
#   Delivers to    Apple notary service   altool → App Store Connect
#   Ships as       Notarized .dmg on      Mac App Store listing
#                  GitHub release
#
# Build number: App Store Connect takes each CFBundleVersion once, so this
# script derives it from the version — major × 10000 + minor × 100 + patch,
# 1.0.3 is 10003 — and CI appends its run number (10003.7) so a release
# branch can run again. BUILD_NUMBER overrides both. Info.plist's own
# CFBundleVersion only reaches the Developer ID build.
#
# Needs (release.env or the environment; see release.env.example):
#   TEAM_ID              the Apple Developer team id
#   APP_STORE_PROFILE    the app's Mac App Store provisioning profile
#   ASC_KEY_JSON         an App Store Connect API key's details as JSON
#                        ({"key_id", "issuer_id", "key_filepath"}), or
#                        APPLE_API_KEY_ID and APPLE_API_ISSUER, with the key
#                        in ~/.appstoreconnect/private_keys/AuthKey_<id>.p8
# and, in the keychain, the team's "Apple Distribution" and "Mac Installer
# Distribution" (or "3rd Party Mac Developer Installer") identities.
#
# The app record must exist in App Store Connect first (Apps → New App). The
# upload adds a build; the listing, and Submit for Review, happen there.
#
set -euo pipefail

source "$(dirname "$0")/build-common.sh"
require_team_id

UPLOAD=false
for arg in "$@"; do
  case "$arg" in
    --upload) UPLOAD=true ;;
    *) die "unknown option: $arg (the only one is --upload)" ;;
  esac
done

CONFIG="ReleaseMAS"
INFO_PLIST="$PROJECT_ROOT/Espresso/Info.plist"
# Bundle ID and version come from Info.plist, the single source of truth.
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO_PLIST")
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")

if [ -z "${BUILD_NUMBER:-}" ]; then
  [[ "$VERSION" =~ ^([0-9]+)\.([0-9]{1,2})(\.([0-9]{1,2}))?$ ]] || \
    die "can't derive a build number from version '$VERSION' (want x.y.z, y and z below 100)"
  BUILD_NUMBER=$(( 10#${BASH_REMATCH[1]} * 10000 + 10#${BASH_REMATCH[2]} * 100 + 10#${BASH_REMATCH[4]:-0} ))
  if [ -n "${BUILD_RUN:-}" ]; then
    BUILD_NUMBER="$BUILD_NUMBER.$BUILD_RUN"
  fi
fi

BUILD_DIR="$PROJECT_ROOT/build-mas"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME-$VERSION-$BUILD_NUMBER.xcarchive"
APP="$BUILD_DIR/$APP_NAME.app"
ENT="$BUILD_DIR/$APP_NAME.entitlements"
PKG="$BUILD_DIR/$APP_NAME-$VERSION-$BUILD_NUMBER.pkg"
ALTOOL_LOG="$BUILD_DIR/altool.log"

# Sanity checks — each of these is a specific prereq; fail early with guidance.
command -v xcodebuild >/dev/null || die "xcodebuild not on PATH"

[ -n "${APP_STORE_PROFILE:-}" ] || die "APP_STORE_PROFILE is not set.
       Point it at the Mac App Store provisioning profile for $BUNDLE_ID
       (release.env, or the environment)."
PROFILE="${APP_STORE_PROFILE/#\~/$HOME}"
[ -f "$PROFILE" ] || die "no provisioning profile at $PROFILE"
[ "$(security cms -D -i "$PROFILE" | plutil -extract Entitlements.com\\.apple\\.application-identifier raw -)" \
    = "$TEAM_ID.$BUNDLE_ID" ] || die "$PROFILE isn't the Mac App Store profile for $TEAM_ID.$BUNDLE_ID"

# The API key, without ever printing it.
if [ -n "${ASC_KEY_JSON:-}" ]; then
  json="${ASC_KEY_JSON/#\~/$HOME}"
  APPLE_API_KEY_ID="$(plutil -extract key_id raw "$json")"
  APPLE_API_ISSUER="$(plutil -extract issuer_id raw "$json")"
fi
[ -n "${APPLE_API_KEY_ID:-}" ] && [ -n "${APPLE_API_ISSUER:-}" ] || \
  die "no App Store Connect API key: set ASC_KEY_JSON, or APPLE_API_KEY_ID and APPLE_API_ISSUER"
[ -f "$HOME/.appstoreconnect/private_keys/AuthKey_$APPLE_API_KEY_ID.p8" ] || \
  die "the API key must be at ~/.appstoreconnect/private_keys/AuthKey_$APPLE_API_KEY_ID.p8, where altool looks"

identity() {
  security find-identity -v -p basic 2>/dev/null | grep -E "\"($1): .*\\($TEAM_ID\\)\"" | head -1 \
    | sed 's/.*"\(.*\)"/\1/' || true
}
SIGN_APP="$(identity "Apple Distribution")"
SIGN_PKG="$(identity "Mac Installer Distribution|3rd Party Mac Developer Installer")"
[ -n "$SIGN_APP" ] || die "Missing 'Apple Distribution' identity for team $TEAM_ID.
       Create one at https://developer.apple.com/account/resources/certificates"
[ -n "$SIGN_PKG" ] || die "Missing 'Mac Installer Distribution' identity for team $TEAM_ID.
       Create one at https://developer.apple.com/account/resources/certificates"

# Only this build's outputs are replaced: build-mas/ also keeps earlier
# archives (their dSYMs) and whatever else lives there, like the App Store
# screenshots.
rm -rf "$ARCHIVE_PATH" "$APP" "$ENT" "$PKG" "$ALTOOL_LOG"
mkdir -p "$BUILD_DIR"

# Archived unsigned and signed below, as xcodebuild -exportArchive would:
# exportArchive segfaults on the CI runners (see release-dmg.sh), and the
# build number is only settled here.
say "1/5  Archive ($CONFIG, sandbox on)"
do_archive "$CONFIG" "$ARCHIVE_PATH" CODE_SIGNING_ALLOWED=NO
ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
[ -d "$ARCHIVED_APP" ] || die "app not found in archive at $ARCHIVED_APP"
ditto "$ARCHIVED_APP" "$APP"

say "2/5  Sign $VERSION ($BUILD_NUMBER) as: $SIGN_APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
# Readable by all: CI writes the profile under umask 077, and the installer
# makes every file root's.
install -m 644 "$PROFILE" "$APP/Contents/embedded.provisionprofile"
# The store wants the app's own entitlements plus who it is, as the profile
# grants them.
cp "$PROJECT_ROOT/Espresso/Espresso-MAS.entitlements" "$ENT"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$BUNDLE_ID" "$ENT"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$ENT"
xattr -cr "$APP"
codesign --force --timestamp --options runtime --sign "$SIGN_APP" --entitlements "$ENT" "$APP"
codesign --verify --deep --strict "$APP"
# Installed, everything is root's: what others can't read, nobody can check
# the signature of, and App Store Connect refuses the package.
private="$(find "$APP" \( -type d ! -perm -o+rx \) -o \( ! -type d ! -perm -o+r \))"
[ -z "$private" ] || die "only root could read these once installed: $private"

say "3/5  Package, signed as: $SIGN_PKG"
productbuild --component "$APP" /Applications --sign "$SIGN_PKG" "$PKG"
pkgutil --check-signature "$PKG" | sed -n 1,3p

KEY=(--apiKey "$APPLE_API_KEY_ID" --apiIssuer "$APPLE_API_ISSUER")
# altool exits 0 even when App Store Connect refuses the package, so what it
# prints on success is the only evidence.
altool() { # <what it prints on success> <arguments…>
  local ok="$1"
  shift
  xcrun altool "$@" 2>&1 | tee "$ALTOOL_LOG" || true
  grep -q "$ok" "$ALTOOL_LOG" || die "App Store Connect refused the package (above)"
}

say "4/5  Validate with App Store Connect"
altool "No errors validating archive" --validate-app -f "$PKG" -t macos "${KEY[@]}"

if $UPLOAD; then
  say "5/5  Upload $VERSION ($BUILD_NUMBER)"
  altool "No errors uploading archive" --upload-app -f "$PKG" -t macos "${KEY[@]}"
  printf "\n\033[1;32m✅ UPLOADED\033[0m\n"
  echo "   It shows in App Store Connect (and TestFlight) once it's processed,"
  echo "   usually within the hour. Then pick the build for the version and"
  echo "   Submit for Review."
else
  printf "\n\033[1;32m✅ VALIDATED\033[0m\n"
  echo "   Package: $PKG"
  echo "   ./submit_mas.sh --upload sends it."
fi
printf "\n"
