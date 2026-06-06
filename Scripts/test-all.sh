#!/usr/bin/env bash
#
# Runs every test suite across the repo's three layers:
#   1. The main SwiftXState package        (swift test, cross-platform)
#   2. The SwiftXChessOpenings example pkg  (swift test)
#   3. The SwiftXChess example app          (xcodebuild test — app + board-actor + UI tests)
#
# Layers 1–2 are the cross-platform gate and run anywhere Swift runs. Layer 3 is macOS/Xcode-only
# (the app's `@testable import SwiftXChess` board-actor tests + UI tests can't run under `swift test`).
#
# Usage: Scripts/test-all.sh [--no-app]   (--no-app skips the xcodebuild layer)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_APP=1
[[ "${1:-}" == "--no-app" ]] && RUN_APP=0

echo "==> [1/3] Main package — swift test"
swift test --package-path "$ROOT"

echo "==> [2/3] SwiftXChessOpenings — swift test"
swift test --package-path "$ROOT/Examples/SwiftXChess/SwiftXChessOpenings"

if [[ "$RUN_APP" == "1" ]]; then
    if command -v xcodebuild >/dev/null 2>&1; then
        echo "==> [3/3] SwiftXChess app — xcodebuild test (macOS)"
        xcodebuild test \
            -project "$ROOT/Examples/SwiftXChess/SwiftXChess.xcodeproj" \
            -scheme SwiftXChess \
            -destination 'platform=macOS' \
            CODE_SIGNING_ALLOWED=NO \
            | xcbeautify 2>/dev/null || \
        xcodebuild test \
            -project "$ROOT/Examples/SwiftXChess/SwiftXChess.xcodeproj" \
            -scheme SwiftXChess \
            -destination 'platform=macOS' \
            CODE_SIGNING_ALLOWED=NO
    else
        echo "==> [3/3] Skipped (xcodebuild not available on this host)"
    fi
else
    echo "==> [3/3] Skipped (--no-app)"
fi

echo "==> All requested test layers passed."
