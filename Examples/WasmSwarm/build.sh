#!/usr/bin/env bash
# Build the Firmware Swarm to an Embedded-Swift wasm module and emit a single,
# self-contained index.html (wasm inlined as base64, worker + loader inlined).
#
# Output: dist/index.html   (open directly — the Web Workers are created from an
#         inline Blob, so no separate files and no server are strictly required,
#         though a server avoids file:// worker restrictions in some browsers)
set -euo pipefail
cd "$(dirname "$0")"

TOOLCHAIN_NAME="swift-DEVELOPMENT-SNAPSHOT-2026-07-11-a"
SWIFT="$HOME/Library/Developer/Toolchains/${TOOLCHAIN_NAME}.xctoolchain/usr/bin/swift"
SDK="DEVELOPMENT-SNAPSHOT-2026-07-11-a-wasm32-unknown-wasip1-embedded"
export TOOLCHAINS="org.swift.65202607111a"

UNICODE=$(find "$HOME/Library/org.swift.swiftpm/swift-sdks" \
  -path "*DEVELOPMENT-SNAPSHOT-2026-07-11-a-wasm32-unknown-wasip1.artifactbundle*embedded/wasm32-unknown-wasip1/libswiftUnicodeDataTables.a" \
  2>/dev/null | head -1)
[[ -n "$UNICODE" ]] || { echo "✗ libswiftUnicodeDataTables.a not found"; exit 1; }

echo "▸ Building Embedded-Swift wasm (release, reactor)…"
"$SWIFT" build -c release --swift-sdk "$SDK" \
  -Xswiftc -enable-experimental-feature -Xswiftc Embedded -Xswiftc -wmo \
  -Xlinker "$UNICODE"

WASM=$(find .build -name "WasmSwarm.wasm" -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1)
[[ -f "$WASM" ]] || { echo "✗ WasmSwarm.wasm not found"; exit 1; }
mkdir -p dist
cp "$WASM" dist/WasmSwarm.wasm
echo "▸ wasm size: $(wc -c < "$WASM" | tr -d ' ') bytes"

echo "▸ Emitting self-contained dist/index.html…"
python3 - "$WASM" web/index.html.template web/loader.js dist/index.html "$TOOLCHAIN_NAME" <<'PY'
import sys, base64, datetime
wasm, template, loader, out, toolchain = sys.argv[1:6]
raw = open(wasm, "rb").read()
kb = len(raw) / 1024.0
size = f"{kb:.0f} KB" if kb >= 100 else f"{kb:.1f} KB"
html = open(template, encoding="utf-8").read()
html = html.replace("__LOADER_JS__", open(loader, encoding="utf-8").read())
html = html.replace("__WASM_SIZE__", size)
html = html.replace("__TOOLCHAIN__", toolchain)
html = html.replace("__BUILD_DATE__", datetime.date.today().isoformat())
html = html.replace("__WASM_BASE64__", base64.b64encode(raw).decode("ascii"))
open(out, "w", encoding="utf-8").write(html)
print(f"    dist/index.html  ({len(html)} bytes, wasm inlined = {size})")
PY
echo "▸ Done."
