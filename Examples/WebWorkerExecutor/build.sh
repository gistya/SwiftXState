#!/usr/bin/env bash
# Build the WebWorkerExecutor probe for full-stdlib wasip1-threads via JavaScriptKit's
# PackageToJS plugin, using the 2026-07-11 snapshot, and emit a headless Node runner.
#
#   ./build.sh && (cd Bundle && node run-node.mjs)
set -euo pipefail
cd "$(dirname "$0")"

TOOLCHAIN="swift-DEVELOPMENT-SNAPSHOT-2026-07-11-a"
SWIFT="$HOME/Library/Developer/Toolchains/${TOOLCHAIN}.xctoolchain/usr/bin/swift"
export TOOLCHAINS="org.swift.65202607111a"
SDK="DEVELOPMENT-SNAPSHOT-2026-07-11-a-wasm32-unknown-wasip1-threads"

echo "▸ Building (PackageToJS, full-stdlib wasip1-threads, JavaScriptKit)…"
# --build-system native is REQUIRED: the default Xcode backend does a per-module
# relocatable prelink (`-r`) that wasm-ld rejects together with `--shared-memory`.
"$SWIFT" package --build-system native --swift-sdk "$SDK" \
    plugin --allow-writing-to-package-directory js --output ./Bundle -c release

echo "▸ Installing JS runtime dep (@bjorn3/browser_wasi_shim)…"
( cd Bundle && npm install --no-save --loglevel=error )

# Headless node runner: node.js platform wires stdout→console and thread-spawn→worker_threads.
printf "import { instantiate } from './instantiate.js';\nimport { defaultNodeSetup } from './platforms/node.js';\nawait instantiate(await defaultNodeSetup({}));\n" > Bundle/run-node.mjs

echo "▸ Done. Run:  (cd Bundle && node run-node.mjs)"
echo "  (Browser: serve Bundle/ with COOP+COEP headers and load index.js — SharedArrayBuffer needs them.)"
