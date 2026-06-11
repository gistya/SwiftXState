#!/usr/bin/env bash
# Builds the Swift → WebAssembly → WebGPU demo into a self-contained static `site/` directory.
# Requires a swift.org WebAssembly SDK (see `swift sdk list`) and Node.js + npm.
set -euo pipefail
cd "$(dirname "$0")"

WASM_SDK="${WASM_SDK:-swift-6.3.2-RELEASE_wasm}"
OUT=".build/plugins/PackageToJS/outputs/Package"

echo "▸ Building wasm + JS bundle (SDK: $WASM_SDK)…"
swift package --swift-sdk "$WASM_SDK" -c release js

echo "▸ Installing the browser WASI shim…"
( cd "$OUT" && npm install --silent --no-audit --no-fund )

echo "▸ Bundling JS with esbuild…"
rm -rf site && mkdir -p site
npx --yes esbuild "$OUT/index.js" --bundle --format=esm --outfile=site/bundle.js

cp "$OUT/WasmGPUDemo.wasm" site/
cp index.html site/
# Embedded true-MSDF atlas (generated offline by tools/make-msdf.mjs) — the default text mode.
# If it's missing, the app falls back to the self-contained runtime SDF at load.
[ -f assets/msdf.png ] && cp assets/msdf.png assets/msdf.json site/ || echo "  (no MSDF atlas — run tools/make-msdf.mjs; the app will fall back to runtime SDF)"
echo "✓ Done. Serve with:  npx --yes serve site"
