#!/bin/bash
#
# build-common.sh — shared configuration and helpers for the Espresso
# build/release scripts (build.sh, notarize.sh, submit_mas.sh).
#
# Source this file, don't run it:
#   source "$(dirname "$0")/build-common.sh"
#
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEME="Espresso"
APP_NAME="Espresso"

# Signing identity. Supply TEAM_ID / APPLE_ID via your shell environment or a
# local, gitignored release.env file (copy release.env.example and fill it in).
# These are intentionally NOT committed so the repo carries no account-specific
# identifiers — the release scripts that need them validate via require_* below.
[ -f "$PROJECT_ROOT/release.env" ] && source "$PROJECT_ROOT/release.env"
TEAM_ID="${TEAM_ID:-}"
APPLE_ID="${APPLE_ID:-}"

say() { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
die() { printf "\n\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }

require_team_id() {
  [ -n "$TEAM_ID" ] || die "TEAM_ID is not set.
       Export it (TEAM_ID=XXXXXXXXXX ./$(basename "$0")) or copy
       release.env.example to release.env and fill in your Apple Team ID."
}
require_apple_id() {
  [ -n "$APPLE_ID" ] || die "APPLE_ID is not set.
       Export it (APPLE_ID=you@example.com ./$(basename "$0")) or copy
       release.env.example to release.env and fill in your Apple ID."
}

# do_archive <configuration> <archive-path>
#
# xcodebuild output is filtered down to the lines that matter; `|| true`
# keeps grep's "no matches" exit from killing a `set -e` script — callers
# verify the produced artifact exists right after.
do_archive() {
  xcodebuild archive \
    -project "$PROJECT_ROOT/Espresso.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$1" \
    -archivePath "$2" \
    -destination "generic/platform=macOS" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    | grep -E "^(\*\*|error:|warning:)" || true
}

# do_export <archive-path> <export-path> <export-options-plist>
do_export() {
  xcodebuild -exportArchive \
    -archivePath "$1" \
    -exportPath "$2" \
    -exportOptionsPlist "$3" \
    | grep -E "^(\*\*|error:|warning:)" || true
}
