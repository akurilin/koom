#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ARGS=()
APP_PATH=""

usage() {
    cat >&2 <<'EOF'
Usage: ./scripts/run.sh [--clean] [--release | --debug] [--app-path PATH]

Options:
  --clean    Remove .build before invoking swift build.
  --release  Build and run a release bundle instead of the default debug bundle.
  --debug    Build and run a debug bundle explicitly.
  --app-path PATH
             Run an already-built app bundle instead of building first.
  --help     Show this help text.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean)
            BUILD_ARGS+=("$1")
            shift
            ;;
        --release | --debug)
            BUILD_ARGS+=("$1")
            shift
            ;;
        --app-path)
            if [[ $# -lt 2 ]]; then
                echo "Missing value for --app-path" >&2
                usage
                exit 1
            fi
            APP_PATH="$2"
            shift 2
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

if [[ -n "$APP_PATH" && ${#BUILD_ARGS[@]} -gt 0 ]]; then
    echo "--app-path cannot be combined with build options." >&2
    usage
    exit 1
fi

if [[ -z "$APP_PATH" ]]; then
    if [[ ${#BUILD_ARGS[@]} -gt 0 ]]; then
        APP_PATH="$("$ROOT_DIR/scripts/build-app.sh" "${BUILD_ARGS[@]}")"
    else
        APP_PATH="$("$ROOT_DIR/scripts/build-app.sh")"
    fi
fi
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/koom"
LOG_FILE="$HOME/Library/Logs/koom/koom.log"

if [[ ! -x "$APP_EXECUTABLE" ]]; then
    echo "koom executable not found at $APP_EXECUTABLE" >&2
    exit 1
fi

app_pid=""
tail_pid=""

# shellcheck disable=SC2329  # invoked indirectly via the `trap` below
cleanup() {
    local received_exit_code=$?
    local exit_code="${1:-$received_exit_code}"

    trap - INT TERM HUP EXIT

    if [[ -n "${tail_pid:-}" ]] && kill -0 "$tail_pid" 2>/dev/null; then
        kill "$tail_pid" 2>/dev/null || true
        wait "$tail_pid" 2>/dev/null || true
    fi

    if [[ -n "${app_pid:-}" ]] && kill -0 "$app_pid" 2>/dev/null; then
        echo "Stopping koom (pid $app_pid)..." >&2
        kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi

    exit "$exit_code"
}

trap cleanup INT TERM HUP EXIT

echo "Launching koom in the foreground. Ctrl-C will stop it." >&2
echo "App bundle: $APP_PATH" >&2
echo "Tailing persistent logs: $LOG_FILE" >&2

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
tail -n 0 -F "$LOG_FILE" &
tail_pid=$!

(
    cd "$ROOT_DIR"
    export NSUnbufferedIO=YES
    # The tailed persistent log is the foreground AppLog stream. Avoid
    # duplicating those lines on stderr while preserving unrelated app
    # stdout/stderr output.
    export KOOM_LOG_TO_STDERR=0
    "$APP_EXECUTABLE"
) &

app_pid=$!
if wait "$app_pid"; then
    exit_code=0
else
    exit_code=$?
fi

cleanup "$exit_code"
