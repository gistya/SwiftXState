#!/usr/bin/env bash
# Build the WasmSwarmLite signal-mesh demo (full-stdlib wasip1, JavaScriptKit) via PackageToJS,
# bundle the JS runtime, and emit a browser entry point.
#
#   ./build.sh && (cd Bundle && python3 -m http.server 8779)   # open http://localhost:8779/
set -euo pipefail
cd "$(dirname "$0")"

TOOLCHAIN="swift-DEVELOPMENT-SNAPSHOT-2026-07-11-a"
SWIFT="$HOME/Library/Developer/Toolchains/${TOOLCHAIN}.xctoolchain/usr/bin/swift"
export TOOLCHAINS="org.swift.65202607111a"
SDK="DEVELOPMENT-SNAPSHOT-2026-07-11-a-wasm32-unknown-wasip1"

echo "▸ Building (PackageToJS · JavaScriptKit 0.56.1 + SwiftXState)…"
"$SWIFT" package --build-system native --swift-sdk "$SDK" \
    plugin --allow-writing-to-package-directory js --output ./Bundle -c release

echo "▸ Installing + bundling the JS runtime…"
( cd Bundle \
  && npm install --no-save --loglevel=error \
  && npx --yes esbuild index.js --bundle --format=esm --outfile=app.bundle.js --log-level=warning )
#   esbuild resolves the bare `@bjorn3/browser_wasi_shim` import that a raw browser can't.

cat > Bundle/index.html <<'HTML'
<!doctype html>
<meta charset="utf-8">
<title>SwiftXState · signal mesh</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<script type="module">
  // The whole UI (canvas + controls) is built by Swift (Sources/App/App.swift); this shell
  // just boots the wasm bundle and surfaces a fatal init error if one happens.
  import { init } from "./app.bundle.js";
  init().catch((e) => {
    document.body.innerHTML =
      "<pre style='color:#f88;font:13px monospace;padding:1.5rem'>init error: " +
      ((e && e.stack) || e) + "</pre>";
  });
</script>
<body style="margin:0;background:#0c0f14;color:#8a97a8;font:15px -apple-system,sans-serif">
  <div style="padding:26px 20px">booting Swift + spawning node actors…</div>
</body>
HTML

echo "▸ Done. Serve Bundle/ and open index.html."
