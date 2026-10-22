# Markdown Notepad — release notes

## 0.2.0 — M5 hardening (board acceptance build)

**Install:** open `Markdown-Notepad-0.2.0-arm64.dmg`, drag **Markdown Notepad** to
Applications, then right-click the app and choose **Open** the first time. Free
ad-hoc-signed build for Apple Silicon, macOS 14 or later.

### Highlights

- **Incremental Markdown highlighting.** Typing only rescans from the edited
  line; the untouched suffix is reused. Measured at 0.05 ms per keystroke in a
  1 MB document and 0.8 ms in a 10 MB document (release build). Full scans run
  off the main thread.
- **File-conflict flow.** Reload / Overwrite / Save As / Cancel is wired and
  covered by a UI test; a vanished file is never silently recreated, and a
  read-only folder/volume offers Save As instead of losing text.
- **Crash recovery.** Unsaved text is snapshotted after edits stop and restored
  after a force-quit. Recovery works for multiple documents, and a dirty
  file-backed document restores its unsaved text rather than stale bytes.
- **Accessibility.** VoiceOver labels for the editor, preview, find controls,
  status bar, and recovery banner; contrast-checked syntax colours in light and
  dark mode (WCAG AA, enforced by tests); all commands reachable by keyboard.
- **Robustness.** Malformed Markdown, unclosed fences, 5,000-row tables,
  thousands of nested list levels, missing local images, and bracket/backtick
  floods are handled without crashes or hangs. Pathological block nesting is
  simplified in the preview only and labelled.
- **Docs.** Full user guide, known limitations, performance measurements, and
  the acceptance checklist are in the repository README and `docs/`.

### Verification

- Linux and macOS core suites, macOS XCUITest acceptance rehearsal, and the
  release workflow are recorded on the issue and in `docs/ACCEPTANCE-REHEARSAL.md`.
- Performance numbers: `docs/PERFORMANCE.md`.

### Known limitations

See "Known limitations (v2 candidates)" in the README. The important ones:
no WYSIWYG typing, no cloud sync/plugins/themes/print, no image paste, and the
first full highlight of a very large file is a background one-off cost.
