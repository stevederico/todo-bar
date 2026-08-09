#!/usr/bin/env bash
# Headless unit + integration smoke for TodoDocument / TodoStore.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT="$ROOT/build/todo-bar-smoke"
mkdir -p "$ROOT/build"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

echo "Compiling smoke harness..."
swiftc \
  -O \
  -target arm64-apple-macos13.0 \
  -sdk "$SDK" \
  -parse-as-library \
  -framework AppKit \
  -framework Combine \
  -o "$OUT" \
  "$ROOT/Sources/TodoBar/TodoDocument.swift" \
  "$ROOT/Sources/TodoBar/TodoStore.swift" \
  "$ROOT/scripts/smoke.swift"

echo "Running smoke..."
"$OUT"
echo "Smoke finished."
