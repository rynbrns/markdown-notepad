#!/usr/bin/env python3
"""Turn an xcodebuild UI-test log into the internal acceptance-rehearsal report."""

from __future__ import annotations

import re
import sys
from pathlib import Path

TEST_LINE = re.compile(
    r"Test Case '-\[MarkdownNotepadUITests\.MarkdownNotepadUITests (?P<name>\w+)\]' "
    r"(?P<status>passed|failed) \((?P<seconds>[0-9.]+) seconds\)"
)

STEPS = [
    {
        "step": "1. Drag the app to Applications and open it",
        "tests": [],
        "automated": "Release workflow: mount .dmg, copy app, verify ad-hoc signature, launch.",
        "manual": "Gatekeeper right-click → Open, and the drag-to-Applications step on the board's Mac.",
    },
    {
        "step": "2. New file; type heading, list, bold, code; toggle preview",
        "tests": ["test04PreviewToggleRendersGFM"],
        "automated": "XCUITest creates a window, types GFM, toggles the preview, checks the rendered heading.",
        "manual": "",
    },
    {
        "step": "3. Save test.md to the Desktop; close and reopen",
        "tests": ["test13AcceptanceRehearsalSaveReopenFindUndo"],
        "automated": "XCUITest writes a real file, saves with ⌘S, closes, and reopens from Open Recent.",
        "manual": "The Desktop path picker and double-clicking the saved file in Finder.",
    },
    {
        "step": "4. Open the file in TextEdit — identical text",
        "tests": [],
        "automated": "Core byte-for-byte round-trip tests (UTF-8, BOM, LF/CRLF, mixed endings, no trailing newline).",
        "manual": "Visual TextEdit comparison on the board's Mac.",
    },
    {
        "step": "5. Edit and ⌘S; reopen in TextEdit — new text is there",
        "tests": ["test10FileConflictOffersReloadOverwriteAndSaveAs", "test13AcceptanceRehearsalSaveReopenFindUndo"],
        "automated": "XCUITest edits, saves, and verifies the file bytes from the test process.",
        "manual": "Opening the result in TextEdit.",
    },
    {
        "step": "6. Close with unsaved changes — prompt; Cancel keeps work",
        "tests": ["test01SmokeLaunchTypeCloseUnsavedPrompt"],
        "automated": "XCUITest closes an edited window, checks Save / Don’t Save / Cancel, cancels, and verifies the text survived.",
        "manual": "",
    },
    {
        "step": "7. Type, force-quit, relaunch — text comes back",
        "tests": ["test11ForceQuitThenRelaunchRestoresUnsavedText"],
        "automated": "XCUITest SIGKILLs the app after the idle snapshot and relaunches against the same state directory; the recovery banner and text are checked.",
        "manual": "",
    },
    {
        "step": "8. Reopen via File → Open Recent",
        "tests": ["test13AcceptanceRehearsalSaveReopenFindUndo"],
        "automated": "XCUITest reopens the saved document from Open Recent.",
        "manual": "",
    },
    {
        "step": "9. Switch dark/light mode — readable",
        "tests": ["test03DarkModeScreenshot", "test02MenusTabsFindAndPromptScreenshots"],
        "automated": "Light and forced-dark screenshots are captured; syntax colours are WCAG AA tested in both appearances.",
        "manual": "Flipping the system appearance on the board's Mac.",
    },
    {
        "step": "10. Find/replace and undo/redo; no beachball",
        "tests": ["test02MenusTabsFindAndPromptScreenshots", "test13AcceptanceRehearsalSaveReopenFindUndo"],
        "automated": "XCUITest exercises find, replace-all, undo, and the find counter; the benchmark records highlighting latency.",
        "manual": "The subjective “no beachball” feel during a long typing session.",
    },
]


def parse(log_path: Path) -> dict[str, tuple[str, str]]:
    results: dict[str, tuple[str, str]] = {}
    if not log_path.exists():
        return results
    for line in log_path.read_text(errors="replace").splitlines():
        match = TEST_LINE.search(line)
        if match:
            results[match.group("name")] = (match.group("status"), match.group("seconds"))
    return results


def main() -> int:
    log_path = Path(sys.argv[1] if len(sys.argv) > 1 else "app/xcodebuild-test.log")
    output = Path(sys.argv[2] if len(sys.argv) > 2 else "app/acceptance-rehearsal.md")
    results = parse(log_path)

    lines = [
        "# Internal acceptance rehearsal — v0.2.0",
        "",
        "Generated from the macOS XCUITest run. The board’s own Mac is still the",
        "final gate for the manual items below.",
        "",
        "| Step | Automated evidence | Result | Board-only check |",
        "| --- | --- | --- | --- |",
    ]

    failures = 0
    for entry in STEPS:
        statuses = [results.get(name) for name in entry["tests"]]
        if not entry["tests"]:
            result = "Covered by core/release checks"
        elif any(status is None for status in statuses):
            result = "NOT RUN"
            failures += 1
        elif any(status[0] == "failed" for status in statuses):
            result = "FAIL"
            failures += 1
        else:
            seconds = sum(float(status[1]) for status in statuses)
            result = f"PASS ({seconds:.1f} s)"
        manual = entry["manual"] or "—"
        lines.append(
            f"| {entry['step']} | {entry['automated']} | {result} | {manual} |"
        )

    lines += [
        "",
        "## Test inventory",
        "",
        "| Test | Result | Duration |",
        "| --- | --- | ---: |",
    ]
    for name in sorted(results):
        status, seconds = results[name]
        lines.append(f"| `{name}` | {status.upper()} | {seconds} s |")
    if not results:
        lines.append("| — | No xcodebuild test results were found in the log | — |")

    lines += [
        "",
        "## Cannot be verified on a CI runner",
        "",
        "- Gatekeeper’s first-launch **right-click → Open** experience (no user session).",
        "- Double-clicking a saved file in Finder and the Desktop save panel.",
        "- Opening the saved file in TextEdit and visually comparing it.",
        "- Listening to VoiceOver output and judging announcement quality.",
        "- Subjective typing feel on the board’s Apple Silicon Mac.",
        "",
        "## Raw sources",
        "",
        f"- xcodebuild log: `{log_path}`",
        "- Screenshots: the XCUITest result bundle and the uploaded screenshot artifacts.",
        "- Performance numbers: `docs/PERFORMANCE.md`.",
        "",
    ]

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines))
    print(f"wrote {output} ({len(results)} tests, {failures} step failures)")
    # The report is evidence, not the test gate: never turn a missing artifact
    # into a second, misleading CI failure.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
