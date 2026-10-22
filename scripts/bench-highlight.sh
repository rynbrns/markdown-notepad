#!/usr/bin/env bash
# Records the Markdown highlighting benchmark used in docs/PERFORMANCE.md.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v swift >/dev/null 2>&1; then
  echo "swift is not installed; install the Swift toolchain first" >&2
  exit 1
fi

swift test -c release --filter testIncrementalHighlightingIsFastAtOneAndTenMegabytes 2>&1 \
  | grep -E "highlight perf|Executed [0-9]+ tests"
