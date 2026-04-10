#!/usr/bin/env bash
#
# Root wrapper for the macOS client install.
# Delegates to client/scripts/install-app.sh so the existing top-level
# command structure stays consistent.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT_DIR/client/scripts/install-app.sh" "$@"
