#!/usr/bin/env bash
# Builds the SwiftXState WebAssembly demo into a self-contained static `site/` directory
# that any static host (GitHub Pages, `npx serve`, …) can serve.
#
# Requirements:
#   - A swift.org WebAssembly SDK installed (see `swift sdk list`). Override with WASM_SDK=…
#   - Node.js + npm (for esbuild + the WASI shim).
set -euo pipefail
cd "$(dirname "$0")"

WASM_SDK="${WASM_SDK:-swift-6.3.2-RELEASE_wasm}"
OUT=".build/plugins/PackageToJS/outputs/Package"

echo "▸ Building wasm + JS bundle with the PackageToJS plugin (SDK: $WASM_SDK)…"
swift package --swift-sdk "$WASM_SDK" -c release js

echo "▸ Installing the browser WASI shim so the bundle is self-contained…"
( cd "$OUT" && npm install --silent --no-audit --no-fund )

echo "▸ Bundling JS with esbuild…"
rm -rf site && mkdir -p site
npx --yes esbuild "$OUT/index.js" --bundle --format=esm --outfile=site/bundle.js

echo "▸ Assembling site/…"
cp "$OUT/WasmDemo.wasm" site/
cp index.html site/

echo "✓ Done. Serve locally with:  npx --yes serve site"
echo "  (or open site/index.html through any static file server)"
