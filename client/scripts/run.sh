#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ARGS=()

usage() {
    cat >&2 <<'EOF'
Usage: ./scripts/run.sh [--clean]

Options:
  --clean    Remove .build before invoking swift build.
  --help     Show this help text.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean)
            BUILD_ARGS+=("$1")
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

if [[ ${#BUILD_ARGS[@]} -gt 0 ]]; then
    APP_PATH="$("$ROOT_DIR/scripts/build-app.sh" "${BUILD_ARGS[@]}")"
else
    APP_PATH="$("$ROOT_DIR/scripts/build-app.sh")"
fi
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/koom"

if [[ ! -x "$APP_EXECUTABLE" ]]; then
    echo "koom executable not found at $APP_EXECUTABLE" >&2
    exit 1
fi

child_pid=""

# shellcheck disable=SC2329  # invoked indirectly via the `trap` below
cleanup() {
    local exit_code=$?

    if [[ -n "${child_pid:-}" ]] && kill -0 "$child_pid" 2>/dev/null; then
        echo "Stopping koom (pid $child_pid)..." >&2
        kill "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
    fi

    trap - INT TERM HUP EXIT
    exit "$exit_code"
}

trap cleanup INT TERM HUP EXIT

echo "Launching koom in the foreground. Ctrl-C will stop it." >&2
echo "App bundle: $APP_PATH" >&2
echo "Persistent logs: $HOME/Library/Logs/koom/koom.log" >&2

(
    cd "$ROOT_DIR"
    export NSUnbufferedIO=YES
    "$APP_EXECUTABLE"
) &

child_pid=$!
wait "$child_pid"
exit_code=$?

trap - INT TERM HUP EXIT
exit "$exit_code"
