#!/usr/bin/env bash
#
# Root test runner for the monorepo.
# Runs the web test suite everywhere, then adds the macOS-only Swift
# package tests when the host can actually build the client target.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT_DIR"

npm run test:web

if [[ "$(uname -s)" == "Darwin" ]]; then
  npm run swift:test
else
  echo "Skipping swift:test on $(uname -s); the client package is macOS-only."
fi
