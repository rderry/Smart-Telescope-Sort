#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/App/Sources"
ICONS="$ROOT/App/Icons"
RESOURCES_SRC="$ROOT/App/Resources"
APP_OUT="$ROOT/Smart Telescope Sort.app"
MACOS="$APP_OUT/Contents/MacOS"
RESOURCES="$APP_OUT/Contents/Resources"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos14.0"
ICON_VARIANT="${ICON_VARIANT:-OS27}"

rm -rf "$APP_OUT"
mkdir -p "$MACOS" "$RESOURCES"
cp "$ROOT/App/Info.plist" "$APP_OUT/Contents/Info.plist"

ICON_SRC="$ICONS/AppIcon-${ICON_VARIANT}.icns"
if [[ ! -f "$ICON_SRC" ]]; then
  echo "Missing icon: $ICON_SRC" >&2
  exit 1
fi
cp "$ICON_SRC" "$RESOURCES/AppIcon.icns"
cp "$ICONS/AppIcon-OS27.icns" "$RESOURCES/AppIcon-OS27.icns" 2>/dev/null || true
cp "$ICONS/AppIcon-OS15.icns" "$RESOURCES/AppIcon-OS15.icns" 2>/dev/null || true
if [[ -f "$RESOURCES_SRC/Smart-Telescope-Sort-User-Manual.pdf" ]]; then
  cp "$RESOURCES_SRC/Smart-Telescope-Sort-User-Manual.pdf" "$RESOURCES/Smart-Telescope-Sort-User-Manual.pdf"
fi
cp "$RESOURCES_SRC/BigSkyAstro-logo.png" "$RESOURCES/BigSkyAstro-logo.png" 2>/dev/null || true

echo "Building Smart Telescope Sort.app ($TARGET, icon $ICON_VARIANT)..."
xcrun swiftc \
  -sdk "$SDK" \
  -target "$TARGET" \
  -parse-as-library \
  -O \
  "$SRC/TelescopeKind.swift" \
  "$SRC/CaptureSorter.swift" \
  "$SRC/LibraryFolders.swift" \
  "$SRC/ContentView.swift" \
  "$SRC/SmartTelescopeSortApp.swift" \
  -o "$MACOS/SmartTelescopeSort" \
  -framework SwiftUI \
  -framework AppKit \
  -framework Foundation

chmod +x "$MACOS/SmartTelescopeSort"
codesign --force --deep --sign - "$APP_OUT" >/dev/null 2>&1 || true
touch "$APP_OUT"
echo "Built: $APP_OUT"
