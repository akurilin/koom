#!/usr/bin/env bash
#
# Root wrapper for provisioning the macOS client's local code-signing identity.
# Delegates to client/scripts/setup-dev-codesign.sh so the top-level command
# stays stable in the monorepo layout.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT_DIR/client/scripts/setup-dev-codesign.sh" "$@"
