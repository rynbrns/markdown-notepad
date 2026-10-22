#!/usr/bin/env bash
# Verify a built Markdown Notepad .dmg end to end:
#   - the image mounts read-only
#   - the app bundle copies out intact
#   - the copied app carries the expected signature
#   - the app launches (skipped with SKIP_LAUNCH=1)
#
# Usage:
#   VERSION=0.1.0 ./scripts/verify-release.sh
#   VERSION=0.1.0 SKIP_LAUNCH=1 ./scripts/verify-release.sh

set -euo pipefail

VERSION="${VERSION:?Set VERSION, for example VERSION=0.1.0}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build"
DMG_NAME="Markdown-Notepad-${VERSION}-arm64.dmg"
DMG="$BUILD_DIR/$DMG_NAME"
MOUNT="$BUILD_DIR/mount"
EXTRACT="$BUILD_DIR/extracted"
APP="$EXTRACT/Markdown Notepad.app"

log() { printf '\n=== %s ===\n' "$*"; }

test -f "$DMG"

rm -rf "$MOUNT" "$EXTRACT"
mkdir -p "$MOUNT" "$EXTRACT"

cleanup() {
  hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
}
trap cleanup EXIT

log "Mount .dmg read-only"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT"
test -d "$MOUNT/Markdown Notepad.app"
test -L "$MOUNT/Applications"
[[ "$(readlink "$MOUNT/Applications")" == "/Applications" ]]

log "Copy app out of the mounted image"
ditto "$MOUNT/Markdown Notepad.app" "$APP"
[[ -x "$APP/Contents/MacOS/MarkdownNotepad" ]]

log "Verify signature of the copied app"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | tee "$BUILD_DIR/codesign-copy.txt"
grep -q 'Signature=adhoc' "$BUILD_DIR/codesign-copy.txt" \
  || echo "Note: copied app is not ad-hoc signed (Developer ID path)."

log "Show quarantined-free bundle metadata"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist"
lipo -info "$APP/Contents/MacOS/MarkdownNotepad"

if [[ "${SKIP_LAUNCH:-0}" == "1" ]]; then
  log "Launch check skipped (SKIP_LAUNCH=1)"
  exit 0
fi

log "Launch app from the copied bundle"
open -n "$APP" || true
sleep 5
if ! pgrep -f "$APP/Contents/MacOS/MarkdownNotepad" >/dev/null; then
  echo "open(1) did not keep the app running; trying the executable directly."
  "$APP/Contents/MacOS/MarkdownNotepad" >/tmp/markdown-notepad-launch.log 2>&1 &
  sleep 5
fi
if ! pgrep -f "$APP/Contents/MacOS/MarkdownNotepad" >/dev/null; then
  echo "ERROR: app did not stay running after launch" >&2
  cat /tmp/markdown-notepad-launch.log 2>/dev/null || true
  exit 1
fi
echo "App process is running."
pkill -f "$APP/Contents/MacOS/MarkdownNotepad" || true
sleep 1
if pgrep -f "$APP/Contents/MacOS/MarkdownNotepad" >/dev/null; then
  echo "ERROR: app did not exit after quit" >&2
  exit 1
fi
echo "App launched and quit cleanly."
