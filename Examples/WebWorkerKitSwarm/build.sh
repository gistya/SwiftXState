#!/usr/bin/env bash
# Build the WebWorkerKit + SwiftXState distributed-actor demo for full-stdlib wasip1
# (NON-threads: WebWorkerKit is message-passing, not shared-memory) via PackageToJS,
# then bundle the JS runtime and emit the browser entry points.
#
#   ./build.sh && (cd Bundle && python3 -m http.server 8778)   # open http://localhost:8778/
set -euo pipefail
cd "$(dirname "$0")"

TOOLCHAIN="swift-DEVELOPMENT-SNAPSHOT-2026-07-11-a"
SWIFT="$HOME/Library/Developer/Toolchains/${TOOLCHAIN}.xctoolchain/usr/bin/swift"
export TOOLCHAINS="org.swift.65202607111a"
SDK="DEVELOPMENT-SNAPSHOT-2026-07-11-a-wasm32-unknown-wasip1"

echo "▸ Building (PackageToJS · WebWorkerKit + JavaScriptKit 0.56.1 + SwiftXState)…"
# --build-system native avoids the per-module `-r` prelink issue seen with the threads
# SDK; it's harmless here and keeps one recipe for both.
"$SWIFT" package --build-system native --swift-sdk "$SDK" \
    plugin --allow-writing-to-package-directory js --output ./Bundle -c release

echo "▸ Installing + bundling the JS runtime…"
( cd Bundle \
  && npm install --no-save --loglevel=error \
  && npx --yes esbuild index.js --bundle --format=esm --outfile=app.bundle.js --log-level=warning )
#   esbuild resolves the bare `@bjorn3/browser_wasi_shim` import that a raw browser can't.

# Browser entry + the classic worker entry. WebWorkerKit detects a worker context via
# `importScripts` (classic-worker-only), so the worker entry is a *classic* script that
# dynamic-imports the ES-module bundle. The workers' `scriptPath` points here — the nil
# default resolves to the `.wasm` path under WASI, which can't be a Worker script.
cat > Bundle/index.html <<'HTML'
<!doctype html>
<meta charset="utf-8">
<title>WebWorkerKit · SwiftXState control room</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<script type="module">
  // The whole interactive UI is built by Swift (Sources/App/UI.swift); this shell just
  // boots the wasm bundle and surfaces a fatal init error if one happens.
  import { init } from "./app.bundle.js";
  init().catch((e) => {
    document.body.innerHTML =
      "<pre style='color:#f88;font:13px monospace;padding:1.5rem'>init error: " +
      ((e && e.stack) || e) + "</pre>";
  });
</script>
<body style="margin:0;background:#0c0f14;color:#8a97a8;font:15px -apple-system,sans-serif">
  <div style="padding:28px 20px">booting Swift + spawning workers…</div>
</body>
HTML
cat > Bundle/worker.js <<'JS'
import('./app.bundle.js').then((m) => m.init()).catch((e) => console.error('worker init error', e));
JS

echo "▸ Done. Serve Bundle/ and open index.html."
