# Performance measurements — v0.2.0

Measured during M5 hardening. Goal: smooth editing at 1 MB and acceptable editing
at 10 MB, with highlighting that does not reparse the whole document on every
keystroke.

## Method

- Benchmark: `Tests/MarkdownCoreTests/MarkdownSyntaxIndexTests.swift`
  (`testIncrementalHighlightingIsFastAtOneAndTenMegabytes`).
- Command: `./scripts/bench-highlight.sh` (`swift test -c release --filter ...`).
- Machine: Intel XPS development box (Ubuntu 26.04, Swift 6.2 release build).
  Apple Silicon is expected to be faster; the numbers below are therefore a
  conservative floor.
- The benchmark builds a realistic Markdown document (headings, emphasis, code
  fences, lists, task lists, quotes, tables), scans it once to fill the index,
  then appends 25 characters at the end and measures the average incremental
  update.
- "Full scan" is the parse work when a document opens or a rich-mode repaint is
  needed. It runs on a background serial queue in the app, so it never blocks
  typing.

## Results (release build)

| Document | Bytes | Full scan | Incremental tail edit |
| --- | ---: | ---: | ---: |
| 1 MB | 1,000,080 | 372 ms | 0.05 ms |
| 10 MB | 10,000,080 | 4,012 ms | 0.81 ms |

Debug-build numbers for comparison: 1 MB full 533 ms / tail 0.06 ms; 10 MB full
5,247 ms / tail 0.93 ms. The incremental path is effectively constant-time for
edits at the end of a document, which is where most typing happens.

## What this means in the app

- Typing does not wait for a whole-file parse. The editor applies the spans for
  the visible range first; the rest of the changed region is applied in small
  main-thread slices.
- Word and line counts are computed off the main thread and debounced by 200 ms,
  so the status bar does not walk a 10 MB string on every keystroke.
- Find matching only runs while the find bar is open.
- Preview rendering (cmark-gfm + HTML) runs on a background queue, generation
  checked, and is not recomputed while the preview is closed.
- A 10 MB document is still a large file: the first colour pass can take a few
  seconds on old hardware, and rendering its preview is a one-off cost. The file
  remains editable immediately.

## Robustness bounds (measured on the same machine, debug build)

| Input | Result |
| --- | --- |
| 200 KB of unmatched `[` | 103 ms, no crash |
| 200 KB of `` `a `` pairs | 97 ms, no crash |
| 200 KB of `*` | 77 ms, no crash |
| 400 KB of `\| - ` | 276 ms, no crash |
| 5,000-row GFM table | preview rendered in 215 ms |
| 5,000-level nested block quote | parser input clamped, rendered in 3 ms |
