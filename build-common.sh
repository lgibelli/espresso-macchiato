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
TEAM_ID="3UFB423D7P"

say() { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
die() { printf "\n\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }

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
