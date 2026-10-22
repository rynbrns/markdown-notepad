# Internal acceptance rehearsal — v0.2.0

Run: [CI 39770053833](https://github.com/rynbrns/markdown-notepad/actions/runs/39770053833) (Linux core + macOS core + full XCUITest suite, 2026-10-22).
Environment: GitHub `macos-14` arm64 runner, Xcode 15.4. Raw log and the
`.xcresult` bundle are attached to [RYA-14](/RYA/issues/RYA-14).

All 10 steps of the board checklist are covered by an automated check. The
"Board-only check" column lists the parts that genuinely require the board's own
Mac; everything else was exercised on CI. A screenshot for every step is
attached as `ui-test-screenshots.zip`.

Generated from the macOS XCUITest run. The board’s own Mac is still the
final gate for the manual items below. A screenshot for every step is attached
to [RYA-14](/RYA/issues/RYA-14) as `ui-test-screenshots.zip`.

| Step | Automated evidence | Result | Board-only check |
| --- | --- | --- | --- |
| 1. Drag the app to Applications and open it | Release workflow: mount .dmg, copy app, verify ad-hoc signature, launch. | Covered by core/release checks | Gatekeeper right-click → Open, and the drag-to-Applications step on the board's Mac. |
| 2. New file; type heading, list, bold, code; toggle preview | XCUITest creates a window, types GFM, toggles the preview, checks the rendered heading. | PASS (15.4 s) | — |
| 3. Save test.md to the Desktop; close and reopen | XCUITest writes a real file, saves with ⌘S, closes, and reopens from Open Recent. | PASS (16.9 s) | The Desktop path picker and double-clicking the saved file in Finder. |
| 4. Open the file in TextEdit — identical text | Core byte-for-byte round-trip tests (UTF-8, BOM, LF/CRLF, mixed endings, no trailing newline). | Covered by core/release checks | Visual TextEdit comparison on the board's Mac. |
| 5. Edit and ⌘S; reopen in TextEdit — new text is there | XCUITest edits, saves, and verifies the file bytes from the test process. | PASS (39.4 s) | Opening the result in TextEdit. |
| 6. Close with unsaved changes — prompt; Cancel keeps work | XCUITest closes an edited window, checks Save / Don’t Save / Cancel, cancels, and verifies the text survived. | PASS (9.8 s) | — |
| 7. Type, force-quit, relaunch — text comes back | XCUITest SIGKILLs the app after the idle snapshot and relaunches against the same state directory; the recovery banner and text are checked. | PASS (32.1 s) | — |
| 8. Reopen via File → Open Recent | XCUITest reopens the saved document from Open Recent. | PASS (16.9 s) | — |
| 9. Switch dark/light mode — readable | Light and forced-dark screenshots are captured; syntax colours are WCAG AA tested in both appearances. | PASS (29.9 s) | Flipping the system appearance on the board's Mac. |
| 10. Find/replace and undo/redo; no beachball | XCUITest exercises find, replace-all, undo, and the find counter; the benchmark records highlighting latency. | PASS (33.1 s) | The subjective “no beachball” feel during a long typing session. |

## Test inventory

| Test | Result | Duration |
| --- | --- | ---: |
| `test00ColdLaunchOpensOneBlankWindowWithEditorFocus` | PASSED | 7.697 s |
| `test00bReopenWithNoWindowsOpensOneBlankWindow` | PASSED | 8.465 s |
| `test00cLaunchingWithFileOpensOnlyThatFile` | PASSED | 7.149 s |
| `test01SmokeLaunchTypeCloseUnsavedPrompt` | PASSED | 9.759 s |
| `test02MenusTabsFindAndPromptScreenshots` | PASSED | 16.164 s |
| `test03DarkModeScreenshot` | PASSED | 13.735 s |
| `test04PreviewToggleRendersGFM` | PASSED | 15.376 s |
| `test05TitleBarRenameCommitsAndCancelKeepsName` | PASSED | 12.214 s |
| `test06MarkdownFormattingShortcuts` | PASSED | 9.733 s |
| `test07EditorModesSwitchAndPersist` | PASSED | 25.804 s |
| `test08AppIconInDockAndFinder` | PASSED | 12.256 s |
| `test10FileConflictOffersReloadOverwriteAndSaveAs` | PASSED | 22.445 s |
| `test11ForceQuitThenRelaunchRestoresUnsavedText` | PASSED | 32.108 s |
| `test12AccessibilityLabelsForEditorToolbarAndPreview` | PASSED | 13.421 s |
| `test13AcceptanceRehearsalSaveReopenFindUndo` | PASSED | 16.933 s |

## Cannot be verified on a CI runner

- Gatekeeper’s first-launch **right-click → Open** experience (no user session).
- Double-clicking a saved file in Finder and the Desktop save panel.
- Opening the saved file in TextEdit and visually comparing it.
- Listening to VoiceOver output and judging announcement quality.
- Subjective typing feel on the board’s Apple Silicon Mac.

## Raw sources

- xcodebuild log: `app/xcodebuild-test.log`
- Screenshots: the XCUITest result bundle and the uploaded screenshot artifacts.
- Performance numbers: `docs/PERFORMANCE.md`.
