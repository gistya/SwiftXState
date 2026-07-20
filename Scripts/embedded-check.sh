#!/bin/bash
# Compile SwiftXState in Embedded Swift mode and report what blocks it.
#
# Embedded Swift is a restricted compilation mode (no reflection, no Codable, no `weak`,
# no `Mutex`, …). Nothing here produces a runnable artifact — the point is the *diagnostics*.
# Output is plain `file:line: error:` so Xcode can parse it if you run this from a Run Script
# phase or an aggregate target.
#
#   ./Scripts/embedded-check.sh                   # summary by cause + by file
#   ./Scripts/embedded-check.sh --errors          # also dump the raw errors
#   ./Scripts/embedded-check.sh --update-baseline # record the current count as the new ceiling
#
# ## The baseline ratchet
#
# The core does not compile under Embedded Swift yet, so "zero errors" is not a usable pass
# condition — CI would be permanently red. Instead the current count is recorded in
# `Scripts/embedded-baseline.txt` and this script fails only when the count *rises* above it.
# That blocks regressions (a new `weak`, a new `Codable` conformance on a wire type) without
# blocking merges on the remaining known work.
#
# When the count drops, the run still passes but prints a reminder to lower the baseline, so the
# ratchet tightens as the migration proceeds and cannot silently slip back.
#
# Requires a toolchain that ships an embedded stdlib. Xcode's bundled toolchain does NOT
# (you'll get "module 'Swift' cannot be imported in embedded Swift mode"); use a swift.org
# toolchain, e.g. `swiftly install 6.3.2`.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TOOLCHAIN="${SWIFTXSTATE_TOOLCHAIN:-6.3.2}"
SDK="${SWIFTXSTATE_EMBEDDED_SDK:-swift-6.3.2-RELEASE_wasm-embedded}"
TARGET="${SWIFTXSTATE_TARGET:-SwiftXState}"
BASELINE_FILE="Scripts/embedded-baseline.txt"
LOG=$(mktemp)
trap 'rm -f "$LOG" "$LOG.err"' EXIT

# `swiftly run +VERSION` selects the toolchain locally. In CI the toolchain is already on PATH,
# so allow driving `swift` directly by setting SWIFTXSTATE_SWIFT=swift.
if [ -n "${SWIFTXSTATE_SWIFT:-}" ]; then
    SWIFT_CMD=("$SWIFTXSTATE_SWIFT")
elif command -v swiftly >/dev/null 2>&1; then
    SWIFT_CMD=(swiftly run "+$TOOLCHAIN" swift)
else
    echo "error: swiftly not found. Install it, or set SWIFTXSTATE_SWIFT to a swift binary" >&2
    echo "       whose toolchain ships an embedded stdlib." >&2
    exit 1
fi

echo "▸ Building $TARGET for Embedded Swift (SDK $SDK)…"
"${SWIFT_CMD[@]}" build --swift-sdk "$SDK" --target "$TARGET" > "$LOG" 2>&1
grep -E "\.swift:[0-9]+:[0-9]+: error:|^<unknown>:0: error:" "$LOG" > "$LOG.err"

COUNT=$(wc -l < "$LOG.err" | tr -d ' ')

# A build can fail for reasons that produce no parseable diagnostics at all — a missing SDK, a
# manifest error, a network failure fetching dependencies. Reporting "0 errors" there would be a
# false green, which is the one outcome this script must never produce.
if [ "$COUNT" -eq 0 ] && ! grep -q "Build complete" "$LOG"; then
    echo "::error::Embedded build produced no diagnostics but did not complete — treating as failure."
    echo "--- last 30 lines of build output ---"
    tail -30 "$LOG"
    exit 1
fi

if [ "${1:-}" = "--update-baseline" ]; then
    # Preserve any leading comment block; replace only the number.
    if [ -f "$BASELINE_FILE" ]; then
        grep '^[[:space:]]*#' "$BASELINE_FILE" > "$BASELINE_FILE.tmp" || true
        echo "$COUNT" >> "$BASELINE_FILE.tmp"
        mv "$BASELINE_FILE.tmp" "$BASELINE_FILE"
    else
        echo "$COUNT" > "$BASELINE_FILE"
    fi
    echo "✅ Baseline updated to $COUNT."
    exit 0
fi

if [ "$COUNT" -eq 0 ]; then
    echo "✅ No errors — $TARGET compiles under Embedded Swift."
    if [ -f "$BASELINE_FILE" ] && [ "$(tr -d '[:space:]' < "$BASELINE_FILE")" != "0" ]; then
        echo "   Set the baseline to 0: ./Scripts/embedded-check.sh --update-baseline"
    fi
    exit 0
fi

OURS=$(grep -c "Sources/$TARGET/" "$LOG.err")
# `<unknown>:0:` errors carry no source location — they are whole-module diagnostics from this
# target, NOT dependency errors. Counting them as dependencies made the warning below fire
# misleadingly.
UNLOCATED=$(grep -c "^<unknown>:0: error:" "$LOG.err")
DEPS=$((COUNT - OURS - UNLOCATED))
echo ""
echo "$COUNT errors — $OURS in Sources/$TARGET, $UNLOCATED whole-module, $DEPS in dependencies."

if [ "$DEPS" -gt 0 ] && [ "$OURS" -eq 0 ]; then
    echo ""
    echo "⚠️  All errors are in dependencies, so your own code was never type-checked."
    echo "   Fix or update the dependency first; this run tells you nothing about $TARGET."
fi

echo ""
echo "── Blockers by cause ──"
for pattern in \
    "cannot find 'Task'::unstructured Task (needs import _Concurrency)" \
    "cannot find 'AsyncStream'::AsyncStream (needs import _Concurrency)" \
    "cannot find 'Mutex'::Synchronization.Mutex (note: Atomic *does* work)" \
    "attribute 'weak'::weak references (prohibited in Embedded)" \
    "isolated' parameter type::actor-isolation plumbing (needs import _Concurrency)" \
    "MutableGlobalVariable::global mutable state (@TaskLocal, static var)" \
    "Codable|Decodable|Encodable|Decoder|CodingKey::Codable family" \
    "Mirror::reflection (Mirror)" \
    "init(describing:)::String(describing:) — use describeValue" \
    "AnyCollection::AnyCollection (Collection/Sequence unavailable)" \
    "checkCancellation::Task.checkCancellation (use Task.isCancelled)" \
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

# --- baseline ratchet ---
if [ ! -f "$BASELINE_FILE" ]; then
    echo ""
    echo "No baseline recorded. Create one: ./Scripts/embedded-check.sh --update-baseline"
    exit 1
fi

# Ignore `#` comment lines so the baseline can carry the reasoning for its current value —
# a bare number with no explanation invites someone to "fix" a rise that was actually progress.
BASELINE=$(grep -v '^[[:space:]]*#' "$BASELINE_FILE" | tr -d '[:space:]')
echo ""
if [ "$COUNT" -gt "$BASELINE" ]; then
    echo "::error::Embedded errors rose from $BASELINE to $COUNT (+$((COUNT - BASELINE)))."
    echo "Something newly added is not Embedded-compatible. The blockers-by-cause table above"
    echo "names the likely culprit; see Sources/SwiftXState/Util/BackRef.swift and"
    echo "Machine/Serialization/CodableConformances.swift for the established patterns."
    exit 1
fi

if [ "$COUNT" -lt "$BASELINE" ]; then
    echo "📉 Errors dropped from $BASELINE to $COUNT. Lower the baseline to lock the gain in:"
    echo "   ./Scripts/embedded-check.sh --update-baseline"
    exit 0
fi

echo "✅ Holding at the baseline of $BASELINE errors — no regression."
exit 0
