#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ARGS=()
app_env=()
ollama_pid=""

AUTOTITLE_DISABLED_VALUES="false 0 no off"
TRUTHY_VALUES="true 1 yes on"
DEFAULT_OLLAMA_URL="http://localhost:11434"
DEFAULT_OLLAMA_MODEL="gemma4:e4b"

usage() {
    cat >&2 <<'EOF'
Usage: ./scripts/run.sh [--clean]

Options:
  --clean    Remove .build before invoking swift build.
  --help     Show this help text.
EOF
}

contains_disabled_value() {
    local value
    value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    for disabled in $AUTOTITLE_DISABLED_VALUES; do
        if [[ "$value" == "$disabled" ]]; then
            return 0
        fi
    done
    return 1
}

contains_truthy_value() {
    local value
    value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    for truthy in $TRUTHY_VALUES; do
        if [[ "$value" == "$truthy" ]]; then
            return 0
        fi
    done
    return 1
}

is_local_ollama_url() {
    [[ "$1" =~ ^https?://(localhost|127\.0\.0\.1)(:[0-9]+)?(/|$) ]]
}

can_autostart_local_ollama() {
    [[ "$1" =~ ^http://(localhost|127\.0\.0\.1)(:[0-9]+)?(/|$) ]]
}

ollama_host_from_url() {
    local host
    host="${1#http://}"
    host="${host#https://}"
    host="${host%%/*}"
    printf '%s' "$host"
}

ollama_port_from_url() {
    local host port
    host="$(ollama_host_from_url "$1")"
    if [[ "$host" == *:* ]]; then
        port="${host##*:}"
    else
        port="80"
    fi
    printf '%s' "$port"
}

ollama_tags_url() {
    printf '%s/api/tags' "${1%/}"
}

ollama_generate_url() {
    printf '%s/api/generate' "${1%/}"
}

ollama_is_reachable() {
    local url
    url="$(ollama_tags_url "$1")"
    curl -sS --max-time 2 --fail "$url" >/dev/null 2>&1
}

ollama_model_present() {
    local url model tags
    url="$(ollama_tags_url "$1")"
    model="$2"
    if ! tags="$(curl -sS --max-time 3 --fail "$url" 2>/dev/null)"; then
        return 1
    fi
    [[ "$tags" == *"\"name\":\"$model\""* ]] ||
        [[ "$tags" == *"\"name\":\"$model:latest\""* ]] ||
        [[ "$model" == *:latest && "$tags" == *"\"name\":\"${model%:latest}\""* ]]
}

start_local_ollama() {
    if [[ -n "${ollama_pid:-}" ]] && kill -0 "$ollama_pid" 2>/dev/null; then
        return 0
    fi

    if ! command -v ollama >/dev/null 2>&1; then
        return 1
    fi

    echo "Ollama is not reachable. Starting local Ollama..." >&2
    OLLAMA_HOST="$(ollama_host_from_url "$KOOM_OLLAMA_URL")" ollama serve >/tmp/koom-ollama.log 2>&1 &
    ollama_pid=$!

    local _
    for _ in $(seq 1 20); do
        if ollama_is_reachable "$KOOM_OLLAMA_URL"; then
            echo "Ollama is reachable at ${KOOM_OLLAMA_URL}." >&2
            return 0
        fi
        sleep 0.5
    done

    echo "Failed to start Ollama. See /tmp/koom-ollama.log for details." >&2
    return 1
}

warm_ollama_model() {
    local url model payload response_file status body
    url="$(ollama_generate_url "$1")"
    model="$2"
    payload="$(printf '{"model":"%s","prompt":"Reply with exactly OK","stream":false,"think":false,"options":{"temperature":0,"num_predict":8},"keep_alive":"15m"}' "$model")"
    response_file="$(mktemp)"

    status="$(curl -sS --max-time 45 -o "$response_file" -w '%{http_code}' \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        "$url" 2>/dev/null || true)"
    body="$(cat "$response_file" 2>/dev/null || true)"
    rm -f "$response_file"

    if [[ "$status" != 2* ]]; then
        echo "Ollama warmup failed for model '$model' (HTTP ${status:-<none>}). ${body}" >&2
        return 1
    fi
    if [[ "$body" != *'"response"'* ]]; then
        echo "Ollama warmup returned an unexpected payload for model '$model': $body" >&2
        return 1
    fi

    echo "Ollama model '$model' responded to warmup." >&2
    return 0
}

stop_started_ollama() {
    if [[ -n "${ollama_pid:-}" ]] && kill -0 "$ollama_pid" 2>/dev/null; then
        echo "Stopping auto-started Ollama (pid $ollama_pid)..." >&2
        kill "$ollama_pid" 2>/dev/null || true
        wait "$ollama_pid" 2>/dev/null || true
        ollama_pid=""
    fi
}

find_local_ollama_pid_on_url() {
    local url port pid command
    url="$1"

    if ! is_local_ollama_url "$url"; then
        return 1
    fi

    port="$(ollama_port_from_url "$url")"
    for pid in $(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null); do
        command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
        case "$command" in
            *"/ollama serve"* | "ollama serve"*)
                printf '%s\n' "$pid"
                return 0
                ;;
        esac
    done

    return 1
}

stop_local_ollama_on_url() {
    local url pid _
    url="$1"

    if [[ -n "${ollama_pid:-}" ]] && kill -0 "$ollama_pid" 2>/dev/null; then
        stop_started_ollama
        return 0
    fi

    if ! pid="$(find_local_ollama_pid_on_url "$url")"; then
        return 1
    fi

    echo "Stopping existing Ollama listener on $(ollama_host_from_url "$url") (pid $pid)..." >&2
    kill "$pid" 2>/dev/null || true

    for _ in $(seq 1 20); do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 0.25
    done

    echo "Existing Ollama process $pid did not exit after SIGTERM." >&2
    return 1
}

restart_local_ollama() {
    local url
    url="$1"

    if ! can_autostart_local_ollama "$url"; then
        return 1
    fi

    stop_local_ollama_on_url "$url" >/dev/null 2>&1 || true
    start_local_ollama
}

handle_ollama_preflight_failure() {
    local require_ready message hint
    require_ready="$1"
    message="$2"
    hint="${3:-}"

    echo "$message" >&2
    if [[ -n "$hint" ]]; then
        echo "$hint" >&2
    fi

    if [[ "$require_ready" == "true" ]]; then
        return 1
    fi

    echo "Disabling auto-title for this run." >&2
    app_env+=("KOOM_AUTOTITLE_ENABLED=false")
    stop_started_ollama
    return 0
}

ensure_ollama_ready_for_run() {
    local autotitle_enabled_raw ollama_require_ready_raw require_ready
    autotitle_enabled_raw="${KOOM_AUTOTITLE_ENABLED:-true}"
    ollama_require_ready_raw="${KOOM_OLLAMA_REQUIRE_READY:-true}"
    require_ready="true"

    if contains_disabled_value "$autotitle_enabled_raw"; then
        echo "Auto-title disabled via KOOM_AUTOTITLE_ENABLED=${autotitle_enabled_raw}." >&2
        return 0
    fi

    if contains_disabled_value "$ollama_require_ready_raw"; then
        require_ready="false"
    elif contains_truthy_value "$ollama_require_ready_raw"; then
        require_ready="true"
    fi

    KOOM_OLLAMA_URL="${KOOM_OLLAMA_URL:-$DEFAULT_OLLAMA_URL}"
    KOOM_OLLAMA_MODEL="${KOOM_OLLAMA_MODEL:-$DEFAULT_OLLAMA_MODEL}"

    if ! ollama_is_reachable "$KOOM_OLLAMA_URL"; then
        if can_autostart_local_ollama "$KOOM_OLLAMA_URL" && ! start_local_ollama; then
            handle_ollama_preflight_failure \
                "$require_ready" \
                "Ollama is not reachable at $KOOM_OLLAMA_URL, and the launcher could not start it." \
                "See /tmp/koom-ollama.log for details."
            return $?
        fi

        if ! ollama_is_reachable "$KOOM_OLLAMA_URL"; then
            local start_hint
            start_hint=""
            if is_local_ollama_url "$KOOM_OLLAMA_URL"; then
                start_hint="Start Ollama with: ollama serve"
            fi
            handle_ollama_preflight_failure \
                "$require_ready" \
                "Ollama is not reachable at $KOOM_OLLAMA_URL." \
                "$start_hint"
            return $?
        fi
    fi

    if ! ollama_model_present "$KOOM_OLLAMA_URL" "$KOOM_OLLAMA_MODEL"; then
        handle_ollama_preflight_failure \
            "$require_ready" \
            "Ollama model '$KOOM_OLLAMA_MODEL' is not pulled." \
            "Pull it with: ollama pull $KOOM_OLLAMA_MODEL"
        return $?
    fi

    if ! warm_ollama_model "$KOOM_OLLAMA_URL" "$KOOM_OLLAMA_MODEL"; then
        if can_autostart_local_ollama "$KOOM_OLLAMA_URL"; then
            echo "Ollama warmup failed. Restarting local Ollama and retrying once..." >&2
            if restart_local_ollama "$KOOM_OLLAMA_URL" && warm_ollama_model "$KOOM_OLLAMA_URL" "$KOOM_OLLAMA_MODEL"; then
                return 0
            fi
        fi

        handle_ollama_preflight_failure \
            "$require_ready" \
            "Ollama warmup failed for model '$KOOM_OLLAMA_MODEL'."
        return $?
    fi

    return 0
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

# macOS still ships bash 3.2, where expanding an empty array as
# "${arr[@]}" under `set -u` is treated as an unbound variable
# (fixed in bash 4.4+). Branch so the "no flags" invocation —
# which is the common case — doesn't trip over that.
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

    if [[ -n "${ollama_pid:-}" ]] && kill -0 "$ollama_pid" 2>/dev/null; then
        echo "Stopping Ollama (pid $ollama_pid)..." >&2
        kill "$ollama_pid" 2>/dev/null || true
        wait "$ollama_pid" 2>/dev/null || true
    fi

    trap - INT TERM HUP EXIT
    exit "$exit_code"
}

trap cleanup INT TERM HUP EXIT

if ! ensure_ollama_ready_for_run; then
    echo "Refusing to launch koom because Ollama is required and failed preflight." >&2
    echo "Set KOOM_OLLAMA_REQUIRE_READY=false to allow a degraded launch, or KOOM_AUTOTITLE_ENABLED=false to disable auto-title entirely." >&2
    exit 1
fi

echo "Launching koom in the foreground. Ctrl-C will stop it." >&2
echo "App bundle: $APP_PATH" >&2
echo "Logs:" >&2

(
    cd "$ROOT_DIR"
    export NSUnbufferedIO=YES
    if [[ ${#app_env[@]} -gt 0 ]]; then
        env "${app_env[@]}" "$APP_EXECUTABLE"
    else
        "$APP_EXECUTABLE"
    fi
) &

child_pid=$!
wait "$child_pid"
exit_code=$?

trap - INT TERM HUP EXIT
exit "$exit_code"
