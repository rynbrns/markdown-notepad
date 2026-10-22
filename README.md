# Markdown Notepad

A native macOS markdown notepad (macOS 14+, Apple Silicon). This repository is at
**M0**: the app shell, the shared core package, and CI exist; editing is a
placeholder and no files are read or written yet.

## Architecture

```
MarkdownCore/                 Foundation-only Swift package (no AppKit/SwiftUI)
  Sources/MarkdownCore/       Document model and statistics
  Tests/MarkdownCoreTests/    Unit tests, runnable on Linux
app/
  project.yml                 XcodeGen spec (source of truth for the Xcode project)
  MarkdownNotepad/            SwiftUI app lifecycle + NSTextView editor
.github/workflows/ci.yml      Linux core tests + macOS app build
scripts/check-core-imports.sh Guard that keeps MarkdownCore free of UI imports
```

**Module boundary:** `MarkdownCore` owns document state and any logic that can be
tested without a UI. It must import Foundation only. The app target owns
AppKit/SwiftUI, windowing, menus, and eventually file I/O. This split lets the
core build and test on Linux in seconds while the GUI is validated on macOS.

**Why XcodeGen:** the checked-in `app/project.yml` is the reproducible project
definition. CI regenerates `MarkdownNotepad.xcodeproj` from it, so there is no
binary project file to merge or hand-edit. Install with `brew install xcodegen`,
then run `xcodegen generate --spec app/project.yml` from the repository root.

**Editor:** SwiftUI `WindowGroup` hosts an `NSTextView` created with a TextKit 2
`NSTextContentStorage` / `NSTextLayoutManager`. Text is plain (no rich text, no
smart substitutions); undo and the find bar are enabled. File commands
(New/Open/Save) are present but disabled placeholders for M1.

## CI

| Job | Runner | What it proves |
| --- | --- | --- |
| `linux-core` | `ubuntu-latest` in the `swift:6.2` container | `swift test` passes and `MarkdownCore` has no UI imports |
| `macos-app` | `macos-14` | XcodeGen regenerates the project and `xcodebuild build` succeeds for arm64 |

Both jobs run on every pull request and on pushes to `main`. SwiftPM/DerivedData
caching keeps the run under the 10-minute budget.

## Running core tests on Linux

Requires a Swift 6.x toolchain (tested with Swift 6.2 on Ubuntu 26.04):

```bash
swift test
./scripts/check-core-imports.sh
```

If Swift is not installed, download the Linux toolchain from
<https://www.swift.org/install/linux/> and add its `usr/bin` to `PATH`.

## Status / limitations

- No real file I/O, markdown preview, packaging, or signing yet (M1/M3/M4).
- The app builds from `app/project.yml`; the generated `.xcodeproj` is ignored
  by git on purpose.
- Not a WYSIWYG editor. The eventual product is a plain-text markdown notepad.
