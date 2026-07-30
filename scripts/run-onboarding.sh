#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPORARY_ROOT="${TMPDIR:-/tmp}"
PROFILE_DIR="$(mktemp -d "${TEMPORARY_ROOT%/}/koom-onboarding.XXXXXX")"

echo "Launching with a fresh onboarding profile: $PROFILE_DIR" >&2
echo "The profile is intentionally left for macOS to clean up." >&2

export KOOM_CLIENT_PROFILE_DIR="$PROFILE_DIR"
export KOOM_ADMIN_SECRETS_FILE="$PROFILE_DIR/admin-secrets.json"

exec "$ROOT_DIR/client/scripts/run.sh" "$@"
