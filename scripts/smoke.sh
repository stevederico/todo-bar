#!/usr/bin/env bash
# Headless smoke: compile TodoStore + smoke harness, run parse/add/complete/edit checks.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT="$ROOT/build/todo-bar-smoke"
mkdir -p "$ROOT/build"

echo "Compiling smoke harness..."
swiftc \
  -O \
  -target arm64-apple-macos13.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -parse-as-library \
  -framework SwiftUI \
  -framework AppKit \
  -framework Combine \
  -o "$OUT" \
  "$ROOT/Sources/TodoBar/TodoStore.swift" \
  "$ROOT/scripts/smoke.swift"

echo "Running smoke..."
"$OUT"
echo "Smoke finished."
