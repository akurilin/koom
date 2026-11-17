#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
BUILD_CONFIGURATION="debug"
APP_PATH=""
EXECUTABLE_PATH=""
APP_ICON_SOURCE_PATH="$ROOT_DIR/assets/camera-lens-glitch.png"
APP_ICON_PATH=""
CLEAN_BUILD=false
DEFAULT_CODESIGN_IDENTITY="koom Local Dev"
KOOM_CODESIGN_IDENTITY="${KOOM_CODESIGN_IDENTITY:-}"
LLAMA_CPP_RELEASE="b10194"
LLAMA_CPP_RUNTIME_DIR=""
UV_RELEASE="0.12.0"
UV_EXECUTABLE_PATH=""

usage() {
    cat >&2 <<'EOF'
Usage: ./scripts/build-app.sh [--clean]

Options:
  --clean    Remove .build before invoking swift build.
  --release  Build a release bundle instead of the default debug bundle.
  --debug    Build a debug bundle explicitly.
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
        --release)
            BUILD_CONFIGURATION="release"
            shift
            ;;
        --debug)
            BUILD_CONFIGURATION="debug"
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

APP_PATH="$BUILD_DIR/$BUILD_CONFIGURATION/koom.app"
EXECUTABLE_PATH="$BUILD_DIR/$BUILD_CONFIGURATION/koom"
APP_ICON_PATH="$APP_PATH/Contents/Resources/AppIcon.icns"

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
    local canonical_root canonical_target allowed_build_dir allowed_configuration_dir
    canonical_root=$(cd "$ROOT_DIR" && pwd -P)
    canonical_target=$(canonicalize_path "$target_path")
    allowed_build_dir="$canonical_root/.build"
    allowed_configuration_dir="$allowed_build_dir/$BUILD_CONFIGURATION"

    if [[ ! -f "$canonical_root/Package.swift" ]]; then
        echo "Refusing to clean because Package.swift was not found at $canonical_root" >&2
        exit 1
    fi

    if [[ "$canonical_target" != "$allowed_build_dir" && "$canonical_target" != "$allowed_configuration_dir" ]]; then
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

reset_app_bundle() {
    local canonical_root canonical_app expected_app
    canonical_root=$(cd "$ROOT_DIR" && pwd -P)
    canonical_app=$(canonicalize_path "$APP_PATH")
    expected_app=$(canonicalize_path \
        "$canonical_root/.build/$BUILD_CONFIGURATION/koom.app")

    if [[ "$canonical_app" != "$expected_app" ]]; then
        echo "Refusing to replace unexpected app path: $canonical_app" >&2
        exit 1
    fi
    if [[ -e "$canonical_app" ]]; then
        rm -rf -- "$canonical_app"
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

prepare_llama_runtime() {
    local architecture archive_name archive_sha256 archive_url
    local vendor_dir archive_path extraction_dir extracted_runtime

    architecture=$(uname -m)
    case "$architecture" in
        arm64)
            archive_name="llama-b10194-bin-macos-arm64.tar.gz"
            archive_sha256="03230460822cd2e69bba70488245f9745198d592874f8ca9c96fd0d808d3f866"
            ;;
        x86_64)
            archive_name="llama-b10194-bin-macos-x64.tar.gz"
            archive_sha256="2304d44161464310ae11e041e3f40f22873d8875e5f8f31f151ee2e21d38f105"
            ;;
        *)
            echo "Unsupported macOS architecture for llama.cpp: $architecture" >&2
            exit 1
            ;;
    esac

    archive_url="https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_CPP_RELEASE/$archive_name"
    vendor_dir="$BUILD_DIR/vendor/llama.cpp/$LLAMA_CPP_RELEASE/$architecture"
    archive_path="$vendor_dir/$archive_name"
    extracted_runtime="$vendor_dir/llama-$LLAMA_CPP_RELEASE"

    mkdir -p "$vendor_dir"
    if [[ ! -f "$archive_path" ]] || \
        ! printf '%s  %s\n' "$archive_sha256" "$archive_path" | shasum -a 256 -c - >/dev/null 2>&1; then
        echo "Downloading pinned llama.cpp runtime ($LLAMA_CPP_RELEASE, $architecture)." >&2
        curl --fail --location --retry 3 --output "$archive_path.part" "$archive_url"
        printf '%s  %s\n' "$archive_sha256" "$archive_path.part" | shasum -a 256 -c - >/dev/null
        mv "$archive_path.part" "$archive_path"
    fi

    if [[ ! -x "$extracted_runtime/llama-server" ]]; then
        extraction_dir=$(mktemp -d "$vendor_dir/extract.XXXXXX")
        tar -xzf "$archive_path" -C "$extraction_dir"
        rm -rf -- "$extracted_runtime"
        mv "$extraction_dir/llama-$LLAMA_CPP_RELEASE" "$extracted_runtime"
        rmdir "$extraction_dir"
    fi

    LLAMA_CPP_RUNTIME_DIR="$extracted_runtime"
}

# uv installs the noise removal helpers (Python environments pinned by each
# helper's uv.lock) on demand at runtime; see NoiseRemovalManager.swift.
prepare_uv_runtime() {
    local architecture uv_target archive_name archive_sha256 archive_url
    local vendor_dir archive_path extraction_dir

    architecture=$(uname -m)
    case "$architecture" in
        arm64)
            uv_target="aarch64-apple-darwin"
            archive_sha256="2b9e582af54f84fa50c115427451a6c13e80f43b52f8282b8af5791077317bbf"
            ;;
        x86_64)
            uv_target="x86_64-apple-darwin"
            archive_sha256="d41593beaefc54bab7d062af0ef6ca093bfb81d001d58ebbef39e44423f9c496"
            ;;
        *)
            echo "Unsupported macOS architecture for uv: $architecture" >&2
            exit 1
            ;;
    esac

    archive_name="uv-$uv_target.tar.gz"
    archive_url="https://github.com/astral-sh/uv/releases/download/$UV_RELEASE/$archive_name"
    vendor_dir="$BUILD_DIR/vendor/uv/$UV_RELEASE/$architecture"
    archive_path="$vendor_dir/$archive_name"

    mkdir -p "$vendor_dir"
    if [[ ! -f "$archive_path" ]] || \
        ! printf '%s  %s\n' "$archive_sha256" "$archive_path" | shasum -a 256 -c - >/dev/null 2>&1; then
        echo "Downloading pinned uv ($UV_RELEASE, $architecture)." >&2
        curl --fail --location --retry 3 --output "$archive_path.part" "$archive_url"
        printf '%s  %s\n' "$archive_sha256" "$archive_path.part" | shasum -a 256 -c - >/dev/null
        mv "$archive_path.part" "$archive_path"
    fi

    if [[ ! -x "$vendor_dir/uv" ]]; then
        extraction_dir=$(mktemp -d "$vendor_dir/extract.XXXXXX")
        tar -xzf "$archive_path" -C "$extraction_dir"
        mv "$extraction_dir/uv-$uv_target/uv" "$vendor_dir/uv"
        rm -rf -- "$extraction_dir"
    fi

    UV_EXECUTABLE_PATH="$vendor_dir/uv"
}

copy_noise_removal_runtime() {
    mkdir -p "$APP_PATH/Contents/Helpers/uv"
    cp "$UV_EXECUTABLE_PATH" "$APP_PATH/Contents/Helpers/uv/uv"

    # Only the helper sources and lockfiles; never local caches or venvs.
    local helper
    for helper in "$ROOT_DIR"/Resources/denoisers/*/; do
        local destination
        destination="$APP_PATH/Contents/Resources/denoisers/$(basename "$helper")"
        mkdir -p "$destination"
        cp "$helper/enhance.py" "$helper/pyproject.toml" "$helper/uv.lock" \
            "$destination/"
    done
}

copy_llama_runtime() {
    local destination
    destination="$APP_PATH/Contents/Helpers/llama-runtime"
    mkdir -p "$destination"

    cp "$LLAMA_CPP_RUNTIME_DIR/llama-server" "$destination/llama-server"
    cp "$LLAMA_CPP_RUNTIME_DIR/LICENSE" "$destination/LICENSE"
    cp -P "$LLAMA_CPP_RUNTIME_DIR"/*.dylib "$destination/"
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

swift build -c "$BUILD_CONFIGURATION" --product koom >&2
prepare_llama_runtime
prepare_uv_runtime
reset_app_bundle

mkdir -p \
    "$APP_PATH/Contents/MacOS" \
    "$APP_PATH/Contents/Resources" \
    "$APP_PATH/Contents/Helpers"

cp "$EXECUTABLE_PATH" "$APP_PATH/Contents/MacOS/koom"
cp "$ROOT_DIR/App/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$ROOT_DIR/Resources/local-title-models.json" \
    "$APP_PATH/Contents/Resources/local-title-models.json"
copy_llama_runtime
copy_noise_removal_runtime
generate_app_icon

sign_app_bundle >/dev/null

printf '%s\n' "$APP_PATH"
