#!/usr/bin/env bash
# Verify that a built Markdown Notepad bundle registers with macOS Launch
# Services as a Markdown editor:
#   - Info.plist claims the Markdown UTIs (no wildcard / public.data hijack)
#   - the app appears in the list of apps that can open a .md file
#   - it can be set as the default handler and Launch Services routes .md to it
#   - launching it with a .md file shows exactly one window, with that file
#
# Runs on macOS only (CI runs it after the macOS build).
#
# Usage:
#   ./scripts/verify-document-types.sh /path/to/MarkdownNotepad.app
#
# Optional:
#   EVIDENCE_FILE=/path/report.md   write a markdown evidence report (default: none)
#   KEEP_APP=1                      leave the app installed in /Applications

set -euo pipefail

APP_SOURCE="${1:?usage: verify-document-types.sh /path/to/MarkdownNotepad.app}"
BUNDLE_ID="com.ryanpaperclip.markdownnotepad"
INSTALLED_APP="/Applications/Markdown Notepad.app"
MARKDOWN_UTI="net.daringfireball.markdown"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

WORK="$(mktemp -d -t markdownnotepad-doctypes)"
PROBE="$WORK/open-probe.json"
REPORT="$WORK/report.md"
LSINFO="$WORK/lsinfo"
trap 'rm -rf "$WORK"' EXIT

log() { printf '\n=== %s ===\n' "$*" | tee -a "$REPORT"; }
fail() { printf '\nERROR: %s\n' "$*" | tee -a "$REPORT" >&2; exit 1; }

: > "$REPORT"

log "Bundle metadata"
/usr/bin/python3 - "$APP_SOURCE/Contents/Info.plist" <<'PY' | tee -a "$REPORT"
import plistlib, sys

with open(sys.argv[1], "rb") as handle:
    info = plistlib.load(handle)

doc_types = info.get("CFBundleDocumentTypes", [])
imported = {
    item.get("UTTypeIdentifier"): item
    for item in info.get("UTImportedTypeDeclarations", [])
}

def fail(message):
    print(f"ERROR: {message}")
    sys.exit(1)

markdown = [d for d in doc_types if "net.daringfireball.markdown" in d.get("LSItemContentTypes", [])]
if not markdown:
    fail("CFBundleDocumentTypes does not claim net.daringfireball.markdown")
if "public.markdown" not in markdown[0]["LSItemContentTypes"]:
    fail("Markdown document type does not also accept public.markdown")
if markdown[0].get("LSHandlerRank") != "Alternate":
    fail("Markdown document type must use LSHandlerRank Alternate")
if markdown[0].get("CFBundleTypeRole") != "Editor":
    fail("Markdown document type must use CFBundleTypeRole Editor")

plain = [d for d in doc_types if "public.plain-text" in d.get("LSItemContentTypes", [])]
if not plain:
    fail("CFBundleDocumentTypes does not declare the public.plain-text fallback")
if plain[0].get("LSHandlerRank") != "Alternate":
    fail("Plain-text fallback must use LSHandlerRank Alternate")

forbidden = {"public.data", "public.text", "public.item", "*"}
for doc in doc_types:
    overlap = forbidden.intersection(doc.get("LSItemContentTypes", []))
    if overlap:
        fail(f"document type hijacks broad UTI(s): {sorted(overlap)}")

declared = imported.get("net.daringfireball.markdown")
if not declared:
    fail("UTImportedTypeDeclarations is missing net.daringfireball.markdown")
if "public.plain-text" not in declared.get("UTTypeConformsTo", []):
    fail("net.daringfireball.markdown must conform to public.plain-text")
extensions = declared.get("UTTypeTagSpecification", {}).get("public.filename-extension", [])
for ext in ("md", "markdown"):
    if ext not in extensions:
        fail(f"net.daringfireball.markdown does not declare .{ext}")

print(f"CFBundleDocumentTypes: {[d.get('CFBundleTypeName') for d in doc_types]}")
print(f"Markdown UTIs: {markdown[0]['LSItemContentTypes']} (rank {markdown[0]['LSHandlerRank']})")
print(f"Plain-text fallback: {plain[0]['LSItemContentTypes']} (rank {plain[0]['LSHandlerRank']})")
print(f"Imported UTI extensions: {extensions}")
print("Info.plist document declarations OK")
PY

log "Compile the Launch Services probe"
cat > "$WORK/lsinfo.swift" <<'SWIFT'
import CoreServices
import Foundation

func urls(for path: String) -> [URL] {
    let url = URL(fileURLWithPath: path) as CFURL
    let list = LSCopyApplicationURLsForURL(url, .all)?.takeRetainedValue() as? [CFURL] ?? []
    return list.map { ($0 as NSURL) as URL }
}

func defaultHandler(for uti: String) -> String? {
    LSCopyDefaultRoleHandlerForContentType(uti as CFString, .all)?
        .takeRetainedValue() as String?
}

let arguments = CommandLine.arguments
switch arguments.count > 1 ? arguments[1] : "" {
case "handlers":
    for app in urls(for: arguments[2]) { print(app.path) }
case "default":
    print(defaultHandler(for: arguments[2]) ?? "none")
case "set-default":
    let status = LSSetDefaultRoleHandlerForContentType(
        arguments[2] as CFString, .all, arguments[3] as CFString
    )
    print(status)
default:
    print("usage: lsinfo handlers <file> | default <uti> | set-default <uti> <bundle-id>")
    exit(2)
}
SWIFT
xcrun swiftc -O -o "$LSINFO" "$WORK/lsinfo.swift"

PREVIOUS_DEFAULT="$("$LSINFO" default "$MARKDOWN_UTI")"
log "Install the app in /Applications and ad-hoc sign it"
if pgrep -f "$INSTALLED_APP/Contents/MacOS/MarkdownNotepad" >/dev/null; then
  pkill -f "$INSTALLED_APP/Contents/MacOS/MarkdownNotepad" || true
  sleep 1
fi
if [[ -d "$INSTALLED_APP" ]]; then
  EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || echo "unknown")"
  [[ "$EXISTING_ID" == "$BUNDLE_ID" ]] \
    || fail "refusing to replace $INSTALLED_APP (bundle id $EXISTING_ID)"
  rm -rf "$INSTALLED_APP"
fi
ditto "$APP_SOURCE" "$INSTALLED_APP"
codesign --force --deep --sign - "$INSTALLED_APP" >/dev/null
codesign --verify --deep --strict "$INSTALLED_APP"
"$LSREGISTER" -f "$INSTALLED_APP"

log "Registered handler claims"
"$LSREGISTER" -dump > "$WORK/lsregister.txt"
if grep -q "$BUNDLE_ID" "$WORK/lsregister.txt"; then
  CLAIMS="$(grep -c "$MARKDOWN_UTI" "$WORK/lsregister.txt" || true)"
  echo "Launch Services knows $BUNDLE_ID; $MARKDOWN_UTI appears $CLAIMS time(s) in the dump" | tee -a "$REPORT"
else
  fail "Launch Services does not know $BUNDLE_ID after registration"
fi

log "Launch Services app list for a .md file"
printf '# Opened from Finder\n\nThis file was opened by Launch Services.\n' > "$WORK/opened.md"

HANDLERS="$("$LSINFO" handlers "$WORK/opened.md")"
printf '%s\n' "$HANDLERS" | tee -a "$REPORT"
if ! printf '%s\n' "$HANDLERS" | grep -qx "$INSTALLED_APP"; then
  fail "Markdown Notepad is not listed as an app that can open .md files"
fi
echo "Open With list includes Markdown Notepad" | tee -a "$REPORT"

log "Set as default, then confirm Launch Services routes .md to the app"
echo "Default handler before registration: $PREVIOUS_DEFAULT" | tee -a "$REPORT"
if [[ "$PREVIOUS_DEFAULT" != "none" && "$PREVIOUS_DEFAULT" != "$BUNDLE_ID" ]]; then
  PRE_REGISTER_DEFAULT="$("$LSINFO" default "$MARKDOWN_UTI")"
  [[ "$PRE_REGISTER_DEFAULT" == "$PREVIOUS_DEFAULT" ]] \
    || fail "registration replaced the existing default handler $PREVIOUS_DEFAULT with $PRE_REGISTER_DEFAULT"
  echo "Registering did not take over the existing default handler" | tee -a "$REPORT"
fi
SET_STATUS="$("$LSINFO" set-default "$MARKDOWN_UTI" "$BUNDLE_ID")"
[[ "$SET_STATUS" == "0" ]] || fail "LSSetDefaultRoleHandlerForContentType returned $SET_STATUS"
CURRENT_DEFAULT="$("$LSINFO" default "$MARKDOWN_UTI")"
echo "Default handler now: $CURRENT_DEFAULT" | tee -a "$REPORT"
[[ "$CURRENT_DEFAULT" == "$BUNDLE_ID" ]] || fail "default handler did not persist"

PLAIN_DEFAULT="$("$LSINFO" default "public.plain-text")"
echo "Default public.plain-text handler: $PLAIN_DEFAULT" | tee -a "$REPORT"
[[ "$PLAIN_DEFAULT" != "$BUNDLE_ID" ]] || fail "app became the default plain-text handler; it must not hijack .txt"

log "Launch with a .md file (one window, file loaded, no blank leftover)"
open -n -a "$INSTALLED_APP" "$WORK/opened.md" --args -openProbe "$PROBE"

for _ in $(seq 1 30); do
  [[ -s "$PROBE" ]] && break
  sleep 1
done
[[ -s "$PROBE" ]] || fail "app did not write the open probe"

cat "$PROBE" | tee -a "$REPORT"

/usr/bin/python3 - "$PROBE" "$WORK/opened.md" <<'PY' | tee -a "$REPORT"
import json, os, sys

with open(sys.argv[1]) as handle:
    probe = json.load(handle)
expected = os.path.realpath(sys.argv[2])
sessions = probe.get("sessions", [])
paths = [os.path.realpath(s["path"]) for s in sessions if s.get("path")]

if probe.get("sessionCount") != 1:
    print(f"ERROR: expected 1 document session, got {probe.get('sessionCount')}")
    sys.exit(1)
if probe.get("visibleWindowCount", 0) > 1:
    print(f"ERROR: expected at most 1 visible window, got {probe.get('visibleWindowCount')}")
    sys.exit(1)
if paths != [expected]:
    print(f"ERROR: expected the opened file {expected}, got {paths}")
    sys.exit(1)
if sessions[0].get("dirty"):
    print("ERROR: opening a file must not mark it edited")
    sys.exit(1)
print("Launch-with-file loaded exactly one window with the requested file")
PY

log "Quit the app and restore the previous default handler"
pkill -f "$INSTALLED_APP/Contents/MacOS/MarkdownNotepad" || true
sleep 1
if [[ "$PREVIOUS_DEFAULT" != "none" && "$PREVIOUS_DEFAULT" != "$BUNDLE_ID" ]]; then
  "$LSINFO" set-default "$MARKDOWN_UTI" "$PREVIOUS_DEFAULT" >/dev/null || true
  echo "Restored default handler to $PREVIOUS_DEFAULT" | tee -a "$REPORT"
fi

if [[ "${KEEP_APP:-0}" != "1" ]]; then
  rm -rf "$INSTALLED_APP"
fi

if [[ -n "${EVIDENCE_FILE:-}" ]]; then
  mkdir -p "$(dirname "$EVIDENCE_FILE")"
  {
    echo "# Markdown document registration verification"
    echo
    echo "Automated on $(sw_vers -productVersion) ($(uname -m)) at $(date -u '+%Y-%m-%dT%H:%M:%SZ')."
    echo
    cat "$REPORT"
  } > "$EVIDENCE_FILE"
  echo "Evidence written to $EVIDENCE_FILE"
fi

log "All document registration checks passed"
