#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$("$ROOT_DIR/scripts/build-app.sh")"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/koom"

if [[ ! -x "$APP_EXECUTABLE" ]]; then
    echo "koom executable not found at $APP_EXECUTABLE" >&2
    exit 1
fi

child_pid=""

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
echo "Logs:" >&2

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
