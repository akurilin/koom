#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_INSTALL_DIR="/Applications"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
CLEAN_BUILD=false
LAUNCH_AFTER_INSTALL=false

usage() {
    cat >&2 <<'EOF'
Usage: ./scripts/install-app.sh [--clean] [--destination DIR] [--launch]

Builds a release koom.app bundle, signs it with the local development
codesigning identity, and installs it into /Applications by default.

Options:
  --clean             Remove the existing release build products first.
  --destination DIR   Install into DIR instead of /Applications.
  --launch            Launch the installed app after copying it.
  --help              Show this help text.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean)
            CLEAN_BUILD=true
            shift
            ;;
        --destination)
            if [[ $# -lt 2 ]]; then
                echo "Missing value for --destination" >&2
                usage
                exit 1
            fi
            INSTALL_DIR="$2"
            shift 2
            ;;
        --launch)
            LAUNCH_AFTER_INSTALL=true
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

canonicalize_existing_or_parent() {
    local target="$1"
    if [[ -e "$target" ]]; then
        (cd "$target" && pwd -P)
        return
    fi

    local parent base
    parent=$(dirname -- "$target")
    base=$(basename -- "$target")
    printf '%s/%s\n' "$(cd "$parent" && pwd -P)" "$base"
}

safe_remove_install_path() {
    local target_path="$1"
    local canonical_install_dir canonical_target
    canonical_install_dir="$(canonicalize_existing_or_parent "$INSTALL_DIR")"
    canonical_target="$(canonicalize_existing_or_parent "$target_path")"

    case "$canonical_target" in
        "$canonical_install_dir/koom.app" | "$canonical_install_dir/.koom.app.installing") ;;
        *)
            echo "Refusing to remove unexpected install target: $canonical_target" >&2
            exit 1
            ;;
    esac

    if [[ -e "$target_path" ]]; then
        rm -rf -- "$target_path"
    fi
}

mkdir -p "$INSTALL_DIR"

echo "Ensuring local codesigning identity exists..." >&2
"$ROOT_DIR/scripts/setup-dev-codesign.sh" >/dev/null

build_args=(--release)
if [[ "$CLEAN_BUILD" == true ]]; then
    build_args+=(--clean)
fi

echo "Building release app bundle..." >&2
APP_PATH="$("$ROOT_DIR/scripts/build-app.sh" "${build_args[@]}")"
INSTALL_PATH="$INSTALL_DIR/koom.app"
TEMP_PATH="$INSTALL_DIR/.koom.app.installing"

if [[ ! -d "$APP_PATH" ]]; then
    echo "Built app bundle not found at $APP_PATH" >&2
    exit 1
fi

safe_remove_install_path "$TEMP_PATH"
safe_remove_install_path "$INSTALL_PATH"

echo "Installing to $INSTALL_PATH..." >&2
ditto "$APP_PATH" "$TEMP_PATH"
mv -f "$TEMP_PATH" "$INSTALL_PATH"
codesign --verify --deep --strict --verbose=2 "$INSTALL_PATH" >/dev/null

if [[ "$LAUNCH_AFTER_INSTALL" == true ]]; then
    open "$INSTALL_PATH"
fi

printf '%s\n' "$INSTALL_PATH"
