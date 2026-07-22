#!/usr/bin/env bash
# Bundle XState v6 core from the local checkout (current commit) into a runnable
# ESM module for the benchmark, plus a minified variant for the size comparison.
# Core is dependency-free, so esbuild bundles src/index.ts directly — no monorepo
# install/build needed. `#is-development` resolves to src/false.ts (production).
set -euo pipefail
cd "$(dirname "$0")"

XSTATE="${XSTATE_REPO:-$HOME/dev/3rdParty/xstate}"
ENTRY="$XSTATE/packages/core/src/index.ts"
[[ -f "$ENTRY" ]] || { echo "✗ XState source not found at $ENTRY (set XSTATE_REPO)"; exit 1; }
mkdir -p vendor

VER=$(node -e "console.log(require('$XSTATE/packages/core/package.json').version)")
COMMIT=$(git -C "$XSTATE" rev-parse --short HEAD 2>/dev/null || echo "?")
echo "▸ XState core $VER (commit $COMMIT) from $XSTATE"

npx --yes esbuild "$ENTRY" --bundle --format=esm --platform=node --conditions=default \
  --outfile=vendor/xstate-core.mjs --log-level=warning
npx --yes esbuild "$ENTRY" --bundle --format=esm --platform=node --conditions=default --minify \
  --outfile=vendor/xstate-core.min.mjs --log-level=warning

echo "▸ vendor/xstate-core.mjs      $(wc -c < vendor/xstate-core.mjs | tr -d ' ') bytes (runnable)"
echo "▸ vendor/xstate-core.min.mjs  $(wc -c < vendor/xstate-core.min.mjs | tr -d ' ') bytes (minified, for size)"
