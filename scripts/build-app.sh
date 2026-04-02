#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT_DIR/.build/koom.app"
EXECUTABLE_PATH="$ROOT_DIR/.build/debug/koom"

cd "$ROOT_DIR"
swift build -c debug --product koom >&2

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

cp "$EXECUTABLE_PATH" "$APP_PATH/Contents/MacOS/koom"
cp "$ROOT_DIR/App/Info.plist" "$APP_PATH/Contents/Info.plist"

codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1 || true

printf '%s\n' "$APP_PATH"
