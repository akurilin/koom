#!/usr/bin/env bash
#
# Root wrapper for the macOS client build.
# Delegates to client/scripts/build-app.sh so the existing top-level
# command keeps working after the monorepo restructure.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT_DIR/client/scripts/build-app.sh" "$@"
