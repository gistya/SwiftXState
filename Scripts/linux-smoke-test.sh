#!/usr/bin/env bash
# Smoke-test SwiftXState on Linux (Ubuntu, etc.).
# Usage: from repo root — ./Scripts/linux-smoke-test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Multipass (and some other) mounts are read-only for .build — keep artifacts in $HOME.
BUILD_PATH="${SWIFTXSTATE_LINUX_BUILD_PATH:-$HOME/swift-build/swift-xstate}"
mkdir -p "$BUILD_PATH"
SWIFT_BUILD=(swift build --build-path "$BUILD_PATH")
SWIFT_TEST=(swift test --build-path "$BUILD_PATH")

echo "==> Swift toolchain"
swift --version
echo "==> Build path: $BUILD_PATH"
echo

echo "==> Build core targets"
"${SWIFT_BUILD[@]}" --target SwiftXState
"${SWIFT_BUILD[@]}" --target SwiftXStateInspect
"${SWIFT_BUILD[@]}" --target SwiftXStateInspectURLSession
echo

echo "==> Core unit tests (SwiftXStateTests)"
"${SWIFT_TEST[@]}" --filter SwiftXStateTests
echo

echo "==> Inspect unit tests (SwiftXStateInspectTests)"
"${SWIFT_TEST[@]}" --filter SwiftXStateInspectTests
echo

echo "Linux smoke test passed."