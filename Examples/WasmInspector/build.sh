#!/usr/bin/env bash
# Builds the SwiftXState browser inspector (Swift → WebAssembly) into a self-contained static `site/`.
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

cp "$OUT/WasmInspector.wasm" site/
cp index.html site/

# MSDF atlas for the Graph tab (generated offline in the WasmGPUDemo example). The graph falls back
# to a runtime-built SDF if it's missing, so this is best-effort.
if [ -f ../WasmGPUDemo/assets/msdf.png ]; then
    cp ../WasmGPUDemo/assets/msdf.png ../WasmGPUDemo/assets/msdf.json site/
else
    echo "  (no MSDF atlas — the Graph tab will fall back to runtime SDF)"
fi

echo "✓ Done. Serve with:  npx --yes serve site"
