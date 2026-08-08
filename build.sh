#!/usr/bin/env bash
# Build todo-bar as a menu-bar .app (no Xcode project required).
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="todo-bar"
EXEC_NAME="TodoBar"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
SRC_DIR="$ROOT/Sources/TodoBar"

mkdir -p "$MACOS_DIR" "$RES_DIR"
rm -rf "$BUILD_DIR/To Do Dash Bar.app" 2>/dev/null || true

echo "Compiling ${APP_NAME}..."
swiftc \
  -O \
  -target arm64-apple-macos13.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -parse-as-library \
  -framework SwiftUI \
  -framework AppKit \
  -framework Combine \
  -o "$MACOS_DIR/$EXEC_NAME" \
  "$SRC_DIR/TodoStore.swift" \
  "$SRC_DIR/TodoSource.swift" \
  "$SRC_DIR/TodoBarModel.swift" \
  "$SRC_DIR/ContentView.swift" \
  "$SRC_DIR/TodoBarApp.swift"

cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

echo "Built: $APP_DIR"
echo "  Run:   open \"$APP_DIR\""
echo "  Install: cp -R \"$APP_DIR\" ~/Applications/"
