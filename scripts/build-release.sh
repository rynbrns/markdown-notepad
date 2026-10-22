#!/usr/bin/env bash
# Build, sign, and package Markdown Notepad for Apple Silicon.
#
# Usage:
#   VERSION=0.1.0 ./scripts/build-release.sh
#
# Default signing is ad-hoc (free, no Apple Developer account). If all of
# APPLE_SIGNING_IDENTITY, APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_PASSWORD are
# present, the app is signed with the Developer ID identity and the resulting
# .dmg is notarized and stapled instead.
#
# Output (under build/):
#   Markdown-Notepad-<version>-arm64.dmg
#   Markdown-Notepad-<version>-arm64.dmg.sha256
#   codesign-app.txt, codesign-copy.txt  (signature evidence)

set -euo pipefail

VERSION="${VERSION:?Set VERSION, for example VERSION=0.1.0}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build"
ARCHIVE="$BUILD_DIR/MarkdownNotepad.xcarchive"
STAGE_ROOT="$BUILD_DIR/dmg-root"
APP="$STAGE_ROOT/Markdown Notepad.app"
DMG_NAME="Markdown-Notepad-${VERSION}-arm64.dmg"
DMG="$BUILD_DIR/$DMG_NAME"

log() { printf '\n=== %s ===\n' "$*"; }

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$STAGE_ROOT"

log "Generate Xcode project"
(cd "$ROOT" && xcodegen generate --spec app/project.yml)

log "Archive Release build (arm64, macOS 14+)"
xcodebuild archive \
  -project app/MarkdownNotepad.xcodeproj \
  -scheme MarkdownNotepad \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath app/.derivedData \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  CODE_SIGNING_ALLOWED=NO \
  SKIP_INSTALL=NO \
  archive

ARCHIVED_APP="$ARCHIVE/Products/Applications/MarkdownNotepad.app"
test -d "$ARCHIVED_APP"

log "Stage app bundle as 'Markdown Notepad.app'"
ditto "$ARCHIVED_APP" "$APP"

log "Sign app (ad-hoc unless Developer ID credentials are supplied)"
if [[ -n "${APPLE_SIGNING_IDENTITY:-}" || -n "${APPLE_ID:-}" || -n "${APPLE_TEAM_ID:-}" || -n "${APPLE_APP_PASSWORD:-}" ]]; then
  : "${APPLE_SIGNING_IDENTITY:?Developer ID signing requires APPLE_SIGNING_IDENTITY}"
  : "${APPLE_ID:?Notarization requires APPLE_ID}"
  : "${APPLE_TEAM_ID:?Notarization requires APPLE_TEAM_ID}"
  : "${APPLE_APP_PASSWORD:?Notarization requires APPLE_APP_PASSWORD}"
  codesign --force --deep --options runtime --timestamp \
    --sign "$APPLE_SIGNING_IDENTITY" "$APP"
  SIGNING_KIND="developer-id"
else
  codesign --force --deep --sign - "$APP"
  SIGNING_KIND="ad-hoc"
fi

log "Verify app signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | tee "$BUILD_DIR/codesign-app.txt"
if [[ "$SIGNING_KIND" == "ad-hoc" ]]; then
  grep -q 'Signature=adhoc' "$BUILD_DIR/codesign-app.txt" \
    || { echo "ERROR: expected an ad-hoc signature" >&2; exit 1; }
fi

log "Verify bundle metadata"
APP_PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PLIST"
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP_PLIST"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST"
/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_PLIST"
lipo -info "$APP/Contents/MacOS/MarkdownNotepad"

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PLIST")" == "com.ryanpaperclip.markdownnotepad" ]] \
  || { echo "ERROR: unexpected bundle identifier" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP_PLIST")" == "Markdown Notepad" ]] \
  || { echo "ERROR: unexpected display name" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST")" == "$VERSION" ]] \
  || { echo "ERROR: unexpected version" >&2; exit 1; }

log "Create .dmg"
ln -s /Applications "$STAGE_ROOT/Applications"
hdiutil create \
  -volname "Markdown Notepad" \
  -srcfolder "$STAGE_ROOT" \
  -ov -format UDZO \
  "$DMG"

log "Notarize and staple (only when Developer ID credentials are supplied)"
if [[ "$SIGNING_KIND" == "developer-id" ]]; then
  xcrun notarytool submit "$DMG" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
else
  echo "No Apple Developer credentials supplied: shipping the ad-hoc-signed .dmg."
fi

log "Checksum"
(cd "$BUILD_DIR" && shasum -a 256 "$DMG_NAME" | tee "$DMG_NAME.sha256")

log "Done: $DMG ($SIGNING_KIND)"
