# Markdown Notepad

A native macOS markdown notepad (macOS 14+, Apple Silicon). This repository is at
**M1**: the file layer is complete and trustworthy, and the app can create,
open, edit, save, save-as, and Trash markdown files.

## Architecture

```
MarkdownCore/                 Foundation-only Swift package (no AppKit/SwiftUI)
  Sources/MarkdownCore/       File format, atomic I/O, fingerprints, recovery
  Tests/MarkdownCoreTests/    Unit tests, runnable on Linux and macOS
app/
  project.yml                 XcodeGen spec (source of truth for the Xcode project)
  MarkdownNotepad/            SwiftUI lifecycle, NSTextView editor, session
.github/workflows/ci.yml      Linux core tests + macOS core tests + app build
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
smart substitutions); undo and the find bar are enabled.

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
| `macos-app` | `macos-14` | `swift test` passes on Darwin file paths, XcodeGen regenerates the project, and `xcodebuild build` succeeds for arm64 |

Both jobs run on every pull request and on pushes to `main`.

## Status / limitations

- No markdown preview, tabs, find/replace UI, packaging, or signing yet (M2–M4).
- Single window in M1; per-window sessions arrive in M2.
- The app builds from `app/project.yml`; the generated `.xcodeproj` is ignored
  by git on purpose.
- Not a WYSIWYG editor. The product is a plain-text markdown notepad.
