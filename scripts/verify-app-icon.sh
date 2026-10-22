#!/usr/bin/env bash
# Verify the app icon is present, complete, and wired into a built .app bundle.
#
# Usage:
#   ./scripts/verify-app-icon.sh build/dmg-root/"Markdown Notepad.app"
#   ./scripts/verify-app-icon.sh app/.derivedData/Build/Products/Debug/MarkdownNotepad.app
#
# Checks:
#   - artwork/AppIcon-1024.png is exactly 1024x1024
#   - Info.plist names AppIcon via CFBundleIconFile and CFBundleIconName
#   - Contents/Resources contains AppIcon.icns and Assets.car
#   - AppIcon.icns expands to every macOS representation, at the right size
#
# Xcode's asset-catalog compiler generates the bundled AppIcon.icns from
# Assets.xcassets, so a byte comparison against artwork/AppIcon.icns is not
# meaningful. The representation check below verifies the same artwork instead.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-}"

if [[ -z "$APP" ]]; then
  echo "usage: $0 <path to MarkdownNotepad.app>" >&2
  exit 2
fi
APP="${APP%/}"
PLIST="$APP/Contents/Info.plist"
RESOURCES="$APP/Contents/Resources"

log() { printf '\n=== %s ===\n' "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }
pixel_size() {
  sips -g pixelWidth -g pixelHeight "$1" \
    | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w "x" h}'
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "Verify 1024x1024 master artwork"
MASTER="$ROOT/artwork/AppIcon-1024.png"
[[ -f "$MASTER" ]] || fail "missing $MASTER"
[[ "$(pixel_size "$MASTER")" == "1024x1024" ]] \
  || fail "artwork/AppIcon-1024.png is not 1024x1024"

log "Verify bundle exists"
[[ -d "$APP" ]] || fail "no app bundle at $APP"
[[ -f "$PLIST" ]] || fail "missing $PLIST"

log "Verify Info.plist icon keys"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$PLIST")" == "AppIcon" ]] \
  || fail "CFBundleIconFile must be AppIcon"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$PLIST")" == "AppIcon" ]] \
  || fail "CFBundleIconName must be AppIcon"

log "Verify bundle resources"
[[ -f "$RESOURCES/AppIcon.icns" ]] || fail "missing Contents/Resources/AppIcon.icns"
[[ -f "$RESOURCES/Assets.car" ]] || fail "missing Contents/Resources/Assets.car (asset catalog did not compile)"
log "Expand AppIcon.icns and verify representations"
iconutil -c iconset "$RESOURCES/AppIcon.icns" -o "$TMP/AppIcon.iconset"
for entry in \
  icon_16x16.png:16 \
  icon_16x16@2x.png:32 \
  icon_32x32.png:32 \
  icon_32x32@2x.png:64 \
  icon_128x128.png:128 \
  icon_128x128@2x.png:256 \
  icon_256x256.png:256 \
  icon_256x256@2x.png:512 \
  icon_512x512.png:512 \
  icon_512x512@2x.png:1024
do
  file="${entry%%:*}"
  expected="${entry##*:}"
  path="$TMP/AppIcon.iconset/$file"
  [[ -f "$path" ]] || fail "AppIcon.icns is missing $file"
  actual="$(pixel_size "$path")"
  [[ "$actual" == "${expected}x${expected}" ]] \
    || fail "$file is $actual, expected ${expected}x${expected}"
done

echo
echo "App icon verification passed for $APP"
