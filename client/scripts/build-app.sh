#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
APP_PATH="$BUILD_DIR/koom.app"
EXECUTABLE_PATH="$BUILD_DIR/debug/koom"
APP_ICON_SOURCE_PATH="$ROOT_DIR/assets/camera-lens-glitch.png"
APP_ICON_PATH="$APP_PATH/Contents/Resources/AppIcon.icns"
CLEAN_BUILD=false
DEFAULT_CODESIGN_IDENTITY="koom Local Dev"
KOOM_CODESIGN_IDENTITY="${KOOM_CODESIGN_IDENTITY:-}"

usage() {
    cat >&2 <<'EOF'
Usage: ./scripts/build-app.sh [--clean]

Options:
  --clean    Remove .build before invoking swift build.
  --help     Show this help text.

Environment:
  KOOM_CODESIGN_IDENTITY
      Optional `codesign` identity to use for signing koom.app.
      Defaults to: koom Local Dev
      Create it with: ./scripts/setup-dev-codesign.sh
      When the selected identity is missing, the bundle is ad hoc
      signed, which means macOS Keychain and TCC trust decisions
      are tied to the current binary hash and may re-prompt after
      rebuilds.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean)
            CLEAN_BUILD=true
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

# Portable replacement for zsh's ${var:A} modifier: resolves symlinks on the
# parent directory via `cd && pwd -P`, which works on both macOS (BSD) and
# Linux without needing GNU realpath's --canonicalize-missing.
canonicalize_path() {
    local target="$1"
    local parent base
    parent=$(dirname -- "$target")
    base=$(basename -- "$target")
    if [[ -d "$parent" ]]; then
        printf '%s/%s\n' "$(cd "$parent" && pwd -P)" "$base"
    else
        printf '%s\n' "$target"
    fi
}

safe_remove_dir() {
    local target_path="$1"
    local canonical_root canonical_target allowed_build_dir
    canonical_root=$(cd "$ROOT_DIR" && pwd -P)
    canonical_target=$(canonicalize_path "$target_path")
    allowed_build_dir="$canonical_root/.build"

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

generate_app_icon() {
    if [[ ! -f "$APP_ICON_SOURCE_PATH" ]]; then
        echo "App icon source not found at $APP_ICON_SOURCE_PATH; continuing without a custom icon." >&2
        return
    fi

    local iconset_dir="$BUILD_DIR/AppIcon.iconset"
    local base_size
    local retina_size

    rm -rf -- "$iconset_dir"
    mkdir -p "$iconset_dir"

    for base_size in 16 32 128 256 512; do
        retina_size=$((base_size * 2))
        sips -z "$base_size" "$base_size" "$APP_ICON_SOURCE_PATH" \
            --out "$iconset_dir/icon_${base_size}x${base_size}.png" >/dev/null
        sips -z "$retina_size" "$retina_size" "$APP_ICON_SOURCE_PATH" \
            --out "$iconset_dir/icon_${base_size}x${base_size}@2x.png" >/dev/null
    done

    iconutil -c icns "$iconset_dir" -o "$APP_ICON_PATH"
}

sign_app_bundle() {
    local sign_identity
    sign_identity="${KOOM_CODESIGN_IDENTITY:-$DEFAULT_CODESIGN_IDENTITY}"

    if security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$sign_identity\"" >/dev/null; then
        echo "Signing app bundle with identity: $sign_identity" >&2
        codesign --force --deep --sign "$sign_identity" "$APP_PATH"
        return
    fi

    if [[ -n "${KOOM_CODESIGN_IDENTITY}" ]]; then
        echo "Configured codesign identity '$sign_identity' was not found. Falling back to ad hoc signing." >&2
    else
        echo "Default codesign identity '$sign_identity' was not found. Falling back to ad hoc signing." >&2
        echo "Run ./scripts/setup-dev-codesign.sh once to create and trust it." >&2
    fi

    echo "Signing app bundle ad hoc." >&2
    echo "Keychain 'Always Allow' decisions will not survive code changes under ad hoc signing; set KOOM_CODESIGN_IDENTITY to a stable certificate to avoid repeated prompts." >&2
    codesign --force --deep --sign - "$APP_PATH"
}

cd "$ROOT_DIR"

if [[ "$CLEAN_BUILD" == true ]]; then
    safe_remove_dir "$BUILD_DIR"
fi

swift build -c debug --product koom >&2

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

cp "$EXECUTABLE_PATH" "$APP_PATH/Contents/MacOS/koom"
cp "$ROOT_DIR/App/Info.plist" "$APP_PATH/Contents/Info.plist"
generate_app_icon

sign_app_bundle >/dev/null

printf '%s\n' "$APP_PATH"
