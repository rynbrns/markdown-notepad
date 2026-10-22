# Markdown Notepad

A native macOS markdown notepad (macOS 14+, Apple Silicon). **v0.2.0** is the
hardened M5 build: trustworthy file handling, native windows and menus, Markdown
highlighting with a live split preview, incremental highlighting that stays
responsive in multi-megabyte files, conflict and crash-recovery flows, accessible
controls, and an installable ad-hoc-signed Apple Silicon `.dmg` produced by CI.

## Using Markdown Notepad

The board acceptance checklist is in
[docs/ACCEPTANCE-REHEARSAL.md](docs/ACCEPTANCE-REHEARSAL.md); release notes are in
[docs/RELEASE-NOTES.md](docs/RELEASE-NOTES.md).

### Open and save

- **New:** ⌘N opens a new window with an untitled document.
- **Open:** ⌘O opens a `.md` or plain-text file in the current window.
- **Open from Finder:** double-click a Markdown file, use **Open With**, or run
  `open -a "Markdown Notepad" notes.md`. An existing window for that file comes
  forward instead of opening a duplicate.
- **Open Recent:** File → Open Recent lists the last 10 files (missing files are
  greyed out).
- **Save:** ⌘S. Save As is ⇧⌘S. The status bar shows the file name and whether
  there are unsaved changes.
- **Revert:** File → Revert to Saved discards edits after a confirmation prompt.
- **Trash:** File → Move to Trash moves the file to the macOS Trash.

Files are written as UTF-8. A byte-order mark and the file's original line
endings (LF, CRLF, or mixed) are preserved. Saves are atomic, so a failed save
cannot damage the original file.

### Markdown highlighting and preview

- Syntax colours appear as you type: headings, emphasis, strong, strikethrough,
  list and task markers, links, images, code, tables, and quotes.
- **⇧⌘P** toggles the rendered GFM preview. On wide windows the preview opens by
  default; once you toggle it yourself the app remembers your choice for that
  window.
- The preview is read-only. It renders local relative images, blocks remote
  resources, and cannot run JavaScript. Links open in your default browser.
- Markdown source is never rewritten. The preview and highlighting only add
  visual attributes.

### Finding text and moving around

- ⌘F find, ⌥⌘F find and replace, ⌘G next match, ⇧⌘G previous match.
- Find is case-insensitive by default; **Aa** matches case, **.\*** enables
  regular expressions. Replace supports `$1` templates for regex searches.
- ⌘L jumps to a line number.
- ⌘Z / ⇧⌘Z undo and redo; standard cut/copy/paste apply.

### Windows, appearance, and zoom

- ⌘N new window, ⌘W close, Window → Merge All Windows, Window → Show Tab Overview.
- View → Word Wrap, Zoom In (⌘+), Zoom Out (⌘−), Actual Size (⌘0), Enter Full
  Screen (⌃⌘F).
- The app follows the system light/dark appearance and uses contrast-checked
  syntax colours in both.

### Recovering unsaved work

- While a document has unsaved changes, the app snapshots it into
  `~/Library/Application Support/MarkdownNotepad/Recovery`. The first snapshot is
  taken about two seconds after you stop typing; afterwards it refreshes every
  30 seconds.
- If the app is force-quit or crashes, the next launch reopens the recovered text
  with a banner that says **Recovered unsaved text after an unexpected quit.**
- The snapshot is deleted after a clean save or a clean quit. It never lives next
  to your document.

### When a file changed outside the app

If another program changes a file after you opened it, ⌘S refuses to overwrite it
silently. You get four choices:

- **Reload** replaces the editor with the version on disk.
- **Overwrite** writes your editor text over the on-disk version.
- **Save As…** writes your text to a new file and leaves the other program's
  version untouched.
- **Cancel** changes nothing.

A file that disappeared while you were editing is never recreated at the old
path; the app offers Save As instead. A read-only folder or volume produces the
same kind of offer instead of an error that loses your text.

### Accessibility and keyboard use

- The editor has the VoiceOver label **Markdown editor**, the preview **Rendered
  Markdown preview**, and the find controls have explicit labels.
- The dirty indicator and document name are exposed to VoiceOver, and the status
  bar reports word and line counts.
- Every command has a menu item and the standard keyboard shortcut, so the app
  can be driven without a mouse.
- Syntax colours meet WCAG AA (4.5:1) contrast against both the standard light
  and dark editor backgrounds; this is enforced by a unit test.

### Markdown that is unusual or hostile

Malformed Markdown, unclosed code fences, huge tables, missing local images,
thousands of nested list levels, and bracket/backtick floods are all handled
without crashing or hanging. Nesting deeper than 24 block levels is simplified
in the preview only (the file is untouched) and labelled as such.

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

Both CI jobs run on every pull request and on pushes to `main`. The release workflow runs on a `v*` tag or manually, and uploads the `.dmg` as a workflow artifact plus a GitHub Release asset.

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
VERSION=0.2.0 ./scripts/build-release.sh
VERSION=0.2.0 ./scripts/verify-release.sh
```

`build-release.sh` writes `build/Markdown-Notepad-0.2.0-arm64.dmg` and its SHA-256. `verify-release.sh` mounts the image, copies the app out, checks the signature, and launches it. Set `SKIP_LAUNCH=1` on a machine without a GUI session.

## Performance

Measured with `./scripts/bench-highlight.sh` (release build, 2 GHz Intel XPS
development machine; Apple Silicon is faster). Full numbers and method are in
[docs/PERFORMANCE.md](docs/PERFORMANCE.md).

| Workload | Full document scan | Edit at the end |
| --- | ---: | ---: |
| 1 MB Markdown | ~0.37 s | ~0.05 ms |
| 10 MB Markdown | ~4.0 s | ~0.8 ms |

The full scan runs off the main thread when a document opens; typing only
rescans from the edited line and reuses the untouched suffix, so editing does not
wait for a whole-file pass. Word/line counts are also computed off the main
thread and debounced.

## Known limitations (v2 candidates)

These are deliberate v1 boundaries, not defects:

- **No WYSIWYG typing.** v1 is a plain-text Markdown notepad with a live rendered
  preview. Hiding markers while typing is a v2 decision.
- No cloud sync, collaboration, iOS/iPadOS app, or App Store distribution.
- No print/PDF export, themes, plugins, or telemetry.
- No image paste or drag-in; images already on disk render in the preview.
- No multi-file search or workspace-wide replace.
- External changes are detected when you save (or use File → Revert to Saved),
  not by continuously watching every open file.
- The first full-document highlight of a 10 MB file takes a few seconds on very
  old hardware; it runs in the background and never blocks typing.
- A crash loses at most the last couple of seconds of typing, because the idle
  snapshot fires about two seconds after edits stop.
- macOS document versions/autosave are not used; Revert to Saved and recovery
  snapshots cover the data-safety paths.
- The app builds from `app/project.yml`; the generated `.xcodeproj` is ignored
  by git on purpose.
- Distribution is ad-hoc signed by default. The first launch needs
  right-click → Open unless an Apple Developer notarization credential is
  supplied.
