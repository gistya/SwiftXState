#!/usr/bin/env bash
# Build SwiftXState to an Embedded-Swift WebAssembly module and emit a single,
# self-contained index.html with the wasm inlined as base64 and all JS inlined.
#
# Output: dist/index.html   (open it directly — no server needed)
#         dist/WasmXStateDemo.wasm   (the raw module, for reference)
#
# Requires the 2026-07-11 development snapshot toolchain + its wasip1-embedded SDK
# (installed via `swift sdk install`).
set -euo pipefail
cd "$(dirname "$0")"

# --- toolchain / SDK (pinned) ---
TOOLCHAIN_NAME="swift-DEVELOPMENT-SNAPSHOT-2026-07-11-a"
TOOLCHAIN_ID="org.swift.65202607111a"
SWIFT="$HOME/Library/Developer/Toolchains/${TOOLCHAIN_NAME}.xctoolchain/usr/bin/swift"
SDK="DEVELOPMENT-SNAPSHOT-2026-07-11-a-wasm32-unknown-wasip1-embedded"
export TOOLCHAINS="$TOOLCHAIN_ID"

# libswiftUnicodeDataTables.a — required to link String-keyed Dictionary / String
# normalization under Embedded Swift. It lives inside the wasip1 SDK bundle.
UNICODE=$(find "$HOME/Library/org.swift.swiftpm/swift-sdks" \
  -path "*DEVELOPMENT-SNAPSHOT-2026-07-11-a*embedded/wasm32-unknown-wasip1/libswiftUnicodeDataTables.a" \
  2>/dev/null | head -1)
if [[ -z "${UNICODE}" ]]; then
  echo "✗ could not find libswiftUnicodeDataTables.a in the wasip1 SDK bundle" >&2
  exit 1
fi

echo "▸ Toolchain: ${TOOLCHAIN_NAME} ($("$SWIFT" --version | head -1 | sed 's/Apple //'))"
echo "▸ SDK:       ${SDK}"
echo "▸ Building Embedded-Swift wasm (release, reactor)…"
"$SWIFT" build -c release \
  --swift-sdk "$SDK" \
  -Xswiftc -enable-experimental-feature -Xswiftc Embedded \
  -Xswiftc -wmo \
  -Xlinker "$UNICODE"

WASM=$(find .build -name "WasmXStateDemo.wasm" -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1)
if [[ -z "${WASM}" || ! -f "${WASM}" ]]; then
  echo "✗ build succeeded but WasmXStateDemo.wasm was not found" >&2
  exit 1
fi

mkdir -p dist
cp "$WASM" dist/WasmXStateDemo.wasm
BYTES=$(wc -c < "$WASM" | tr -d ' ')
echo "▸ wasm size: ${BYTES} bytes"

echo "▸ Emitting self-contained dist/index.html…"
python3 - "$WASM" web/index.html.template web/loader.js dist/index.html "$TOOLCHAIN_NAME" <<'PY'
import sys, base64, datetime
wasm, template, loader, out, toolchain = sys.argv[1:6]
raw = open(wasm, "rb").read()
b64 = base64.b64encode(raw).decode("ascii")
kb = len(raw) / 1024.0
size = f"{kb:.0f} KB" if kb >= 100 else f"{kb:.1f} KB"
date = datetime.date.today().isoformat()
html = open(template, encoding="utf-8").read()
html = html.replace("__LOADER_JS__", open(loader, encoding="utf-8").read())
html = html.replace("__WASM_SIZE__", size)
html = html.replace("__TOOLCHAIN__", toolchain)
html = html.replace("__BUILD_DATE__", date)
html = html.replace("__WASM_BASE64__", b64)   # last (largest)
open(out, "w", encoding="utf-8").write(html)
print(f"    dist/index.html  ({len(html)} bytes, wasm inlined = {size})")
PY

echo "▸ Done. Open dist/index.html directly, or run: node web/smoke.mjs dist/WasmXStateDemo.wasm"
