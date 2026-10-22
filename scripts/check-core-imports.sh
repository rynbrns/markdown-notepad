#!/usr/bin/env bash
# MarkdownCore must stay Foundation-only so it can build and test on Linux.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -d Sources/MarkdownCore ]]; then
  echo "error: Sources/MarkdownCore not found" >&2
  exit 1
fi

if grep -RInE '^[[:space:]]*(public[[:space:]]+)?import[[:space:]]+(AppKit|SwiftUI|UIKit|Cocoa|Combine)[[:space:]]*$' Sources/MarkdownCore; then
  echo "error: MarkdownCore imports a UI framework; keep it Foundation-only" >&2
  exit 1
fi

echo "MarkdownCore import check passed (Foundation-only)."
