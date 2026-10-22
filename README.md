# Markdown Notepad

A native macOS markdown notepad (macOS 14+, Apple Silicon). This repository is at
**M2**: the file layer is trustworthy and the app now ships the native shell —
multi-window and tabs, a full menu bar, unsaved-changes prompts, recents,
find/replace, dark mode, and session restoration.

## Architecture

```
MarkdownCore/                 Foundation-only Swift package (no AppKit/SwiftUI)
  Sources/MarkdownCore/       File format, atomic I/O, fingerprints, recovery
  Tests/MarkdownCoreTests/    Unit tests, runnable on Linux and macOS
app/
  project.yml                 XcodeGen spec (source of truth for the Xcode project)
  MarkdownNotepad/            SwiftUI lifecycle, per-window sessions, NSTextView editor
  MarkdownNotepadUITests/     XCUITest smoke + screenshot suite
.github/workflows/ci.yml      Linux core tests + macOS core tests + build + UI tests
scripts/check-core-imports.sh Guard that keeps MarkdownCore free of UI imports
```

**Module boundary:** `MarkdownCore` owns document state and all file logic that
can be tested without a UI. It imports Foundation only. The app target owns
AppKit/SwiftUI, windowing, menus, panels, and prompts. This split lets the core
build and test on Linux in seconds while the GUI is validated on macOS.

**Why XcodeGen:** the checked-in `app/project.yml` is the reproducible project
definition. CI regenerates `MarkdownNotepad.xcodeproj` from it, so there is no
binary project file to merge or hand-edit. Install with `brew install xcodegen`,
then run `xcodegen generate --spec app/project.yml` from the repository root.

**Editor:** SwiftUI `WindowGroup` hosts an `NSTextView` created with a TextKit 2
`NSTextContentStorage` / `NSTextLayoutManager`. Text is plain (no rich text, no
smart substitutions); undo and a custom find/replace bar (case-insensitive
default, regex toggle, replace-all, match highlighting) are available.

## Native shell (M2)

- **Windows and tabs:** ⌘N opens a window, ⌘O opens in the current window, ⌘W
  closes the window/tab, and `Window > Merge All Windows` / `Show Tab Overview`
  use the native window tabbing system.
- **Menus:** File (New, Open, Open Recent, Close, Save, Save As, Revert to Saved,
  Move to Trash), Edit (undo/redo/cut/copy/paste plus Find ⌘F, Replace ⌥⌘F, Find
  Next/Previous, Go to Line ⌘L), View (Word Wrap, Zoom In/Out/Actual Size, Full
  Screen), Window, and Help.
- **Dirty state:** one `DocumentSession` per window backed by the Foundation-only
  `DocumentDirtyState`. The window dirty dot, the "Edited" status, and the
  Save / Don't Save / Cancel prompts on close, quit, and revert all read from it.
  Cancel always preserves work and the crash-recovery snapshot.
- **Recents and restoration:** File > Open Recent keeps the last 10 paths and
  greys out missing ones. Open file-backed windows are recorded and reopened on
  the next launch; untitled documents fall back to crash recovery.
- **Find bar:** literal search is case-insensitive by default, `Aa` opts into
  case-sensitive, `.*` enables ICU regular expressions (errors are shown), and
  matches are highlighted in the editor. Replace supports `$1` templates for
  regex searches.
- **Appearance:** semantic AppKit colours throughout, so light/dark mode follows
  the system; UI tests force dark mode and capture a screenshot.

## File-format guarantees (M1)

- **Read** decodes UTF-8, records a BOM if present, and normalizes CRLF/CR to LF
  only in memory. Invalid UTF-8 fails with a clear, non-destructive error.
- **Write** is atomic: a temp file is created in the destination directory,
  written, fsynced, chmod-matched to the original, then swapped in with
  `FileManager.replaceItemAt` on macOS (atomic `rename` on Linux). The parent
  directory is fsynced afterwards. A failure at any stage leaves the original
  file untouched and removes the temp file.
- **BOM and every original line terminator are preserved.** Untouched files
  round-trip byte for byte, including mixed LF/CRLF files. Edited documents use
  the dominant original terminator for new lines; mixed endings are labelled in
  the status bar.
- **External changes are detected** with a size plus SHA-256 content fingerprint
  captured at open time. A save refuses to overwrite a changed file and offers
  Reload / Overwrite / Save As. Touching mtime without changing bytes is not a
  conflict.
- **Crash recovery** snapshots dirty text into
  `~/Library/Application Support/MarkdownNotepad/Recovery` (never the document
  folder) about 2 seconds after edits stop and every 30 seconds while dirty.
  Snapshots restore on the next launch and are deleted on a clean save or quit.
- **Trash** uses the macOS Trash via `FileManager.trashItem`; the Linux test
  path implements the freedesktop Trash specification.

## Running core tests on Linux

Requires a Swift 6.x toolchain (tested with Swift 6.2 on Ubuntu 26.04):

```bash
swift test
./scripts/check-core-imports.sh
```

On macOS (also run in CI):

```bash
swift test
```

If Swift is not installed, download the Linux toolchain from
<https://www.swift.org/install/linux/> and add its `usr/bin` to `PATH`.

## CI

| Job | Runner | What it proves |
| --- | --- | --- |
| `linux-core` | `ubuntu-latest` in the `swift:6.2` container | `swift test` passes and `MarkdownCore` has no UI imports |
| `macos-app` | `macos-14` | `swift test` passes on Darwin file paths, XcodeGen regenerates the project, `xcodebuild build` succeeds for arm64, and the XCUITest smoke + screenshot suite passes |

Both jobs run on every pull request and on pushes to `main`.

## Status / limitations

- Markdown highlighting and the split preview are M3; packaging and signing are M4.
- macOS document versions/autosave are not part of M2; Revert to Saved and
  crash-recovery snapshots cover the data-safety paths.
- The app builds from `app/project.yml`; the generated `.xcodeproj` is ignored
  by git on purpose.
- Not a WYSIWYG editor. The product is a plain-text markdown notepad.
