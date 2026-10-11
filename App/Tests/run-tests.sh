#!/bin/bash
# Compiles the sorter with its tests for this Mac's CPU only (debug, one compiler process) and runs them.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/App/Sources"
BINS="$ROOT/.build-bins/tests"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "$BINS"
xcrun swiftc \
  -sdk "$SDK" \
  -target "$(uname -m)-apple-macos15.0" \
  -parse-as-library \
  -Onone \
  "$SRC/TelescopeKind.swift" \
  "$SRC/CaptureSorter.swift" \
  "$SRC/Credits.swift" \
  "$ROOT/App/Tests/CaptureSorterTests.swift" \
  -framework PDFKit \
  -o "$BINS/CaptureSorterTests"
"$BINS/CaptureSorterTests" "$BINS"
