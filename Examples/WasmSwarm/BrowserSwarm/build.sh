#!/usr/bin/env bash
# Build the BrowserSwarm (all-JS XState.js twin) into a single self-contained
# index.html: the worker (XState + swarm.mjs) is bundled by esbuild and inlined.
set -euo pipefail
cd "$(dirname "$0")"

XSTATE="${XSTATE_REPO:-$HOME/dev/3rdParty/xstate}"
VER=$(node -e "console.log(require('$XSTATE/packages/core/package.json').version)" 2>/dev/null || echo "6.x")
[[ -f vendor/xstate-core.mjs ]] || { echo "✗ vendor/xstate-core.mjs missing — run: (cd '$XSTATE' && npx esbuild packages/core/src/index.ts --bundle --format=esm --platform=node --conditions=default --outfile=$(pwd)/vendor/xstate-core.mjs)"; exit 1; }
mkdir -p dist

echo "▸ Bundling worker (XState v6 $VER + swarm)…"
npx --yes esbuild worker-entry.mjs --bundle --format=iife --platform=browser \
  --outfile=dist/worker.bundle.js --log-level=warning

MINBYTES=$(wc -c < vendor/xstate-core.min.mjs | tr -d ' ')
echo "▸ Emitting self-contained dist/index.html…"
python3 - index.html.template dist/worker.bundle.js dist/index.html "$VER" "$MINBYTES" <<'PY'
import sys, datetime
template, bundle, out, ver, minbytes = sys.argv[1:6]
size = f"{int(minbytes)/1024:.0f} KB"
worker = open(bundle, encoding="utf-8").read().replace("</script>", "<\\/script>")  # keep it inside the tag
html = open(template, encoding="utf-8").read()
html = html.replace("__WORKER_BUNDLE__", worker)
html = html.replace("__XSTATE_SIZE__", size)
html = html.replace("__XSTATE_VERSION__", ver)
html = html.replace("__BUILD_DATE__", datetime.date.today().isoformat())
open(out, "w", encoding="utf-8").write(html)
print(f"    dist/index.html  ({len(html)} bytes, worker bundle inlined)")
PY
echo "▸ Done."
