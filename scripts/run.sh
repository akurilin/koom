#!/bin/zsh
#
# Root wrapper for running the macOS client.
# Delegates to client/scripts/run.sh so the existing top-level command
# keeps working after the monorepo restructure.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT_DIR/client/scripts/run.sh" "$@"
