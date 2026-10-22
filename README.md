# Markdown Notepad

A native macOS markdown notepad (macOS 14+, Apple Silicon). This repository is at
**M2 + M4**: the file layer is trustworthy, the app ships the native shell —
multi-window and tabs, a full menu bar, unsaved-changes prompts, recents,
find/replace, dark mode, and session restoration — and CI produces an
installable ad-hoc-signed Apple Silicon `.dmg`.

## Architecture

```
MarkdownCore/                 Swift package (no AppKit/SwiftUI in the core)
  Sources/MarkdownCore/       File format, atomic I/O, fingerprints, recovery,
                              syntax spans, preview visibility policy
  Sources/MarkdownPreview/    GFM parser + sanitising HTML renderer
                              (swift-markdown / cmark-gfm)
  Tests/                      Unit tests, runnable on Linux and macOS
app/
  project.yml                 XcodeGen spec (source of truth for the Xcode project)
  MarkdownNotepad/            SwiftUI lifecycle, per-window sessions, NSTextView editor
  MarkdownNotepadUITests/     XCUITest smoke + screenshot suite
.github/workflows/ci.yml      Linux core tests + macOS core tests + build + UI tests
artwork/                      Original app icon: 1024 master, iconset, .icns
scripts/check-core-imports.sh Guard that keeps MarkdownCore free of UI imports
scripts/generate-app-icon.py  Reproducible Pillow generator for the artwork
scripts/verify-app-icon.sh    Checks icon files, plist keys, and bundle wiring
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
- **Interactive title bar:** the window title is a native title-bar accessory.
  Double-click it (or press ⌘R / File > Rename…) to edit the document name;
  Return commits and Escape cancels. A disclosure chevron beside the title opens
  a popover showing the current folder and a **Choose Folder…** button backed by
  a native `NSOpenPanel` directory picker. The file is moved (or, for an
  untitled document, saved) only after the move/save confirmation.
- **Rename and save-location safety:** names are normalized to one `.md`
  filename (`notes` → `notes.md`; an existing extension is kept, so
  `notes.txt` → `notes.txt.md`). Slashes, colons, control characters, empty
  names, and hidden-dot names are rejected. Rename and folder moves use
  no-clobber semantics: if the destination exists, the operation is refused and
  neither file is changed. Untitled documents remember the new name and use it
  on the next save. `representedURL` and the window `title` stay in sync for
  tabs, the Window menu, and VoiceOver.

## Editor modes

The same Markdown document can be shown in three modes. Switching never
rewrites the buffer, so the Markdown round-trips byte-for-byte and the cursor,
selection, scroll position, undo history, and unsaved changes are preserved.

| Mode | Shortcut | What it shows |
| --- | --- | --- |
| Plain Text | ⌃⌘1 | Raw Markdown source with syntax colouring, no preview |
| Panels | ⌃⌘2 | Source editor beside the live rendered GFM preview (M3 split view) |
| WYSIWYG | ⌃⌘3 | Rendered rich text with Markdown markers hidden while editing |

A fresh install starts in Plain Text. The last mode you choose becomes the
default for new windows and is restored on the next launch.

- **Three switch paths:** compact icon buttons in the status bar, **View >
  Editor Mode** in the menu bar, and the direct ⌃⌘1/2/3 shortcuts. All three
  stay in sync and the active mode is named in the status bar.
- **Persisted default:** the last mode you choose becomes the default for new
  windows and is restored on the next launch
  (`~/Library/Application Support/MarkdownNotepad/EditorMode.json`).
- **⇧⌘P / View > Preview** still toggles the Panels preview off and back on,
  returning to the previous non-Panels mode.
- **WYSIWYG is source-preserving:** it hides inline markers such as `**`, `*`,
  `` ` ``, `~~`, heading `#`s, blockquote `>`s, and code fences by styling
  them at near-zero width and transparent colour. List bullets and task boxes
  remain as source markers; tables and code blocks are styled but not converted.
  Because no text is converted to a separate rich-text model, there is no
  Markdown round-trip to corrupt.

## Markdown formatting shortcuts

The **Editor** menu exposes every formatting command with its shortcut glyph.
Commands work on the current selection, or on the current line when there is no
selection, and a multi-line selection is transformed line by line. Each command
is one undoable edit, so ⌘Z restores the previous text exactly.

| Action | Shortcut | Behaviour |
| --- | --- | --- |
| Bold | ⌘B | Toggles `**` around the selection or inserts a pair at the caret |
| Italic | ⌘I | Toggles `*`; applying it to bold text produces `***` |
| Strikethrough | ⇧⌘X | Toggles `~~` |
| Inline code | ⌘\` | Toggles a backtick span |
| Code block | ⌥⌘C | Wraps the selected lines in a fenced block, or removes the surrounding fences |
| Heading 1–6 | ⌘1 … ⌘6 | Sets the level on every selected non-blank line; pressing the same level again removes the heading |
| Unordered list | ⇧⌘8 | Toggles `- ` on the selected non-blank lines |
| Ordered list | ⇧⌘7 | Numbers the selected lines from 1, or continues the preceding list number |
| Increase list indent | ⌘] | Adds two leading spaces to selected list items |
| Decrease list indent | ⌘[ | Removes up to two leading spaces from selected list items |
| Blockquote | ⌥⌘Q | Toggles `> ` on the selected non-blank lines |
| Insert link | ⌘K | Wraps the selection as `[text](url)` and selects the `url` placeholder; if the pasteboard holds an http/https/mailto URL, that destination is used |

Inside a list, **Tab** and **Shift-Tab** also increase and decrease nesting by two
spaces; everywhere else they keep the standard text-view behaviour.

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
| `release` (`.github/workflows/release.yml`) | `macos-14` | archives a Release arm64 build, ad-hoc signs it, mounts the `.dmg`, copies the app out, verifies the signature, launches the app, and publishes the `.dmg` |

`linux-core` runs on every pull request, every push to `main`, and manual
dispatch. `macos-app` runs only for pull requests, pushes to `main`, and manual
dispatch; a feature-branch push starts no run by itself. The XCUITest suite runs
once per macOS job. See [`docs/ci.md`](docs/ci.md) for the cost accounting and
the local commands that avoid GitHub macOS minutes. The release workflow runs on
a `v*` tag or manually, and uploads the `.dmg` as a workflow artifact plus a
GitHub Release asset.

## App icon

The icon is original geometric artwork generated by `scripts/generate-app-icon.py`.
It uses no fonts or third-party images. The committed outputs are the 1024x1024
master, the macOS `.iconset`/`.icns`, and the asset-catalog entry wired into the
app target (`CFBundleIconFile` / `CFBundleIconName` = `AppIcon`).

Regenerate after changing the generator:

```bash
python3 -m pip install pillow
python3 scripts/generate-app-icon.py
```

`scripts/verify-app-icon.sh <path-to-app>` checks the master size, plist keys,
the bundled `AppIcon.icns` and `Assets.car`, and every iconset representation.
The build and release scripts run it automatically.

## Install (Apple Silicon, macOS 14+)

1. Download `Markdown-Notepad-<version>-arm64.dmg` from the issue or the GitHub Release.
2. Open the `.dmg`, drag **Markdown Notepad** to **Applications**, and eject the disk image.
3. Right-click **Markdown Notepad** in Applications and choose **Open** the first time.

The build is ad-hoc signed, so macOS may warn that the app is from an unidentified developer. If it reports the app is damaged, run this once in Terminal:

```bash
xattr -dr com.apple.quarantine "/Applications/Markdown Notepad.app"
```

## Opening Markdown files from Finder

The app registers itself with Launch Services as a Markdown editor, so it shows
up in **Open With** without taking over any file type at install time:

- `Info.plist` claims `net.daringfireball.markdown` (declared as an imported type
  that conforms to `public.plain-text`, with `.md`, `.markdown`, `.mdown`,
  `.mkdn`, `.mkd`, `.markdn` extensions), also accepts `public.markdown`, and
  keeps a `public.plain-text` fallback so plain-text files can still be opened
  on request.
- Every document type uses `LSHandlerRank = Alternate` and
  `CFBundleTypeRole = Editor`. The app never becomes a default handler on its
  own, and it does not claim `public.data` or a wildcard extension.
- Double-clicking a `.md` file, right-click → **Open With**, or
  `open -a "Markdown Notepad" notes.md` loads that file into one editor window
  and suppresses the extra blank window. If the same file is already open, its
  window is brought forward instead of opening a second copy.

To make Markdown Notepad the **default** Markdown app:

1. In Finder, select any `.md` file.
2. Press ⌘I (**Get Info**), open **Open with**, and choose **Markdown Notepad**.
3. Click **Change All…**, then **Continue**.

Or right-click the file → **Open With** → **Other…**, pick **Markdown Notepad**,
and tick **Always Open With**. Undo the same way by choosing another app.

To verify the registration on a Mac (checks the plist claims, the Open With
list, Set as Default, and a real launch-with-file run):

```bash
./scripts/verify-document-types.sh "/Applications/Markdown Notepad.app"
```

CI runs the same script on every macOS build and uploads the report as
`document-type-verification.md`.

## Building and verifying a release locally

Requires macOS 14+, Xcode 15.4+, and `brew install xcodegen`.

```bash
VERSION=0.1.0 ./scripts/build-release.sh
VERSION=0.1.0 ./scripts/verify-release.sh
```

`build-release.sh` writes `build/Markdown-Notepad-0.1.0-arm64.dmg` and its SHA-256. `verify-release.sh` mounts the image, copies the app out, checks the signature, and launches it. Set `SKIP_LAUNCH=1` on a machine without a GUI session.

## Status / limitations

- Markdown highlighting and the split preview are M3; packaging and signing are M4.
- macOS document versions/autosave are not part of M2; Revert to Saved and
  crash-recovery snapshots cover the data-safety paths.
- The app builds from `app/project.yml`; the generated `.xcodeproj` is ignored
  by git on purpose.
- Double-clicking this app's title bar starts a rename instead of the system
  "double-click title bar to zoom/minimize" action, matching the product
  request. The title bar remains draggable for moving the window.
- Not a WYSIWYG editor. The product is a plain-text markdown notepad.
