#!/bin/bash
# Compile SwiftXState in Embedded Swift mode and report what blocks it.
#
# Embedded Swift is a restricted compilation mode (no reflection, no Codable, no `weak`,
# no unstructured `Task`, …). Nothing here produces a runnable artifact — the point is the
# *diagnostics*. Output is plain `file:line: error:` so Xcode can parse it if you run this
# from a Run Script phase or an aggregate target.
#
#   ./Scripts/embedded-check.sh            # summary by cause + by file
#   ./Scripts/embedded-check.sh --errors   # also dump the raw errors
#
# Requires a toolchain that ships an embedded stdlib. Xcode's bundled toolchain does NOT
# (you'll get "module 'Swift' cannot be imported in embedded Swift mode"); use a swift.org
# toolchain, e.g. `swiftly install 6.3.2`.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TOOLCHAIN="${SWIFTXSTATE_TOOLCHAIN:-6.3.2}"
SDK="${SWIFTXSTATE_EMBEDDED_SDK:-swift-6.3.2-RELEASE_wasm-embedded}"
TARGET="${SWIFTXSTATE_TARGET:-SwiftXState}"
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

if ! command -v swiftly >/dev/null 2>&1; then
    echo "error: swiftly not found — install it, or set SWIFTXSTATE_TOOLCHAIN and edit this script." >&2
    exit 1
fi

echo "▸ Building $TARGET for Embedded Swift (toolchain $TOOLCHAIN, SDK $SDK)…"
swiftly run "+$TOOLCHAIN" swift build --swift-sdk "$SDK" --target "$TARGET" > "$LOG" 2>&1
grep -E "\.swift:[0-9]+:[0-9]+: error:|^<unknown>:0: error:" "$LOG" > "$LOG.err"

if [ ! -s "$LOG.err" ]; then
    echo "✅ No errors — $TARGET compiles under Embedded Swift."
    exit 0
fi

OURS=$(grep -c "Sources/$TARGET/" "$LOG.err")
DEPS=$(grep -vc "Sources/$TARGET/" "$LOG.err")
echo ""
echo "❌ $(wc -l < "$LOG.err" | tr -d ' ') errors — $OURS in Sources/$TARGET, $DEPS in dependencies."

if [ "$DEPS" -gt 0 ] && [ "$OURS" -eq 0 ]; then
    echo ""
    echo "⚠️  All errors are in dependencies, so your own code was never type-checked."
    echo "   Fix or update the dependency first; this run tells you nothing about $TARGET."
fi

echo ""
echo "── Blockers by cause ──"
for pattern in \
    "cannot find 'Task'::unstructured Task (needs the concurrency runtime)" \
    "cannot find 'AsyncStream'::AsyncStream" \
    "cannot find 'Mutex'::Synchronization.Mutex (note: Atomic *does* work)" \
    "attribute 'weak'::weak references (prohibited in Embedded, no workaround)" \
    "isolated' parameter type::actor-isolation plumbing" \
    "MutableGlobalVariable::global mutable state (@TaskLocal, static var)" \
    "Codable|Decodable|Encodable|Decoder|CodingKey::Codable family" \
    "Mirror::reflection (Mirror)" \
    ; do
    pat="${pattern%%::*}"; label="${pattern#*::}"
    n=$(grep -Ec "$pat" "$LOG.err")
    [ "$n" -gt 0 ] && printf "  %5d  %s\n" "$n" "$label"
done

echo ""
echo "── Worst files (Sources/$TARGET) ──"
grep "Sources/$TARGET/" "$LOG.err" \
    | sed "s|.*Sources/$TARGET/||;s|:.*||" \
    | sort | uniq -c | sort -rn | head -12 \
    | awk '{printf "  %5d  %s\n", $1, $2}'

if [ "${1:-}" = "--errors" ]; then
    echo ""
    echo "── Raw errors ──"
    sed 's|.*/SwiftXState/||' "$LOG.err"
fi

echo ""
echo "(Nothing above is a runtime failure — Embedded mode is compile-only here.)"
exit 1
