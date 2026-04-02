#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
APP_PATH="$BUILD_DIR/koom.app"
EXECUTABLE_PATH="$BUILD_DIR/debug/koom"

safe_remove_dir() {
    local target_path="$1"
    local canonical_root="${ROOT_DIR:A}"
    local canonical_target="${target_path:A}"
    local allowed_build_dir="${canonical_root}/.build"

    if [[ ! -f "$canonical_root/Package.swift" ]]; then
        echo "Refusing to clean because Package.swift was not found at $canonical_root" >&2
        exit 1
    fi

    if [[ "$canonical_target" != "$allowed_build_dir" ]]; then
        echo "Refusing to delete unexpected path: $canonical_target" >&2
        exit 1
    fi

    if [[ "$canonical_target" == "/" || "$canonical_target" == "$HOME" || "$canonical_target" == "." ]]; then
        echo "Refusing to delete unsafe path: $canonical_target" >&2
        exit 1
    fi

    if [[ -e "$canonical_target" ]]; then
        echo "Cleaning build directory: $canonical_target" >&2
        rm -rf -- "$canonical_target"
    fi
}

cd "$ROOT_DIR"
safe_remove_dir "$BUILD_DIR"
swift build -c debug --product koom >&2

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

cp "$EXECUTABLE_PATH" "$APP_PATH/Contents/MacOS/koom"
cp "$ROOT_DIR/App/Info.plist" "$APP_PATH/Contents/Info.plist"

codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1 || true

printf '%s\n' "$APP_PATH"
