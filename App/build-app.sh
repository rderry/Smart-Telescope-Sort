#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=macos-bundle.sh
source "$ROOT/App/macos-bundle.sh"
SRC="$ROOT/App/Sources"
ICONS="$ROOT/App/Icons"
RESOURCES_SRC="$ROOT/App/Resources"
APP_OUT="$ROOT/Telescope Data Sort.app"
MACOS="$APP_OUT/Contents/MacOS"
RESOURCES="$APP_OUT/Contents/Resources"
ENT_LOCAL="$ROOT/App/Entitlements-Local.plist"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
MIN_OS="15.0"
ARCHS=(arm64 x86_64)
BINS="$ROOT/.build-bins"
ICON_VARIANT="${ICON_VARIANT:-OS27}"
PLIST="$ROOT/App/Info.plist"

rm -rf "$APP_OUT"
mkdir -p "$MACOS" "$RESOURCES" "$BINS"
cp "$PLIST" "$APP_OUT/Contents/Info.plist"

ICON_SRC="$ICONS/AppIcon-${ICON_VARIANT}.icns"
if [[ ! -f "$ICON_SRC" ]]; then
  echo "Missing icon: $ICON_SRC" >&2
  exit 1
fi
cp "$ICON_SRC" "$RESOURCES/AppIcon.icns"
cp "$ICONS/AppIcon-OS27.icns" "$RESOURCES/AppIcon-OS27.icns" 2>/dev/null || true
cp "$ICONS/AppIcon-OS15.icns" "$RESOURCES/AppIcon-OS15.icns" 2>/dev/null || true
if [[ -f "$RESOURCES_SRC/Telescope-Data-Sort-User-Manual.pdf" ]]; then
  cp "$RESOURCES_SRC/Telescope-Data-Sort-User-Manual.pdf" "$RESOURCES/Telescope-Data-Sort-User-Manual.pdf"
fi
cp "$RESOURCES_SRC/BigSkyAstro-logo.png" "$RESOURCES/BigSkyAstro-logo.png" 2>/dev/null || true
cp "$RESOURCES_SRC/GitHub-logo.png" "$RESOURCES/GitHub-logo.png" 2>/dev/null || true

echo "Building Telescope Data Sort.app (universal ${ARCHS[*]}, macOS $MIN_OS+, icon $ICON_VARIANT)..."
info_plist_ldflags "$PLIST"
PIDS=()
for arch in "${ARCHS[@]}"; do
  xcrun swiftc \
    -sdk "$SDK" \
    -target "${arch}-apple-macos${MIN_OS}" \
    -parse-as-library \
    -O \
    "${INFO_PLIST_LDFLAGS[@]}" \
    "$SRC/TelescopeKind.swift" \
    "$SRC/CaptureSorter.swift" \
    "$SRC/LibraryFolders.swift" \
    "$SRC/AgreementRecord.swift" \
    "$SRC/Credits.swift" \
    "$SRC/CreditsView.swift" \
    "$SRC/ContentView.swift" \
    "$SRC/SmartTelescopeSortApp.swift" \
    -o "$BINS/SmartTelescopeSort-$arch" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Foundation &
  PIDS[${#PIDS[@]}]=$!
done
for pid in "${PIDS[@]}"; do
  wait "$pid"
done
lipo -create "$BINS/SmartTelescopeSort-arm64" "$BINS/SmartTelescopeSort-x86_64" -output "$MACOS/SmartTelescopeSort"
chmod +x "$MACOS/SmartTelescopeSort"
# Assets.car before the signature, or the seal is stale and Launch Services refuses the app.
compile_asset_catalog "$APP_OUT" "$ROOT/App/Assets.xcassets" "$BINS/actool-partial.plist" "$MIN_OS"
sign_local_adhoc "$APP_OUT" "$ENT_LOCAL"
rm -rf "$BINS"

install_local_test_app "$APP_OUT" "$ENT_LOCAL" "$ROOT"
echo "Built: $APP_OUT"
echo "Installed local test app (ad-hoc): /Applications/$LOCAL_APPSTORE_APP_NAME"
echo "Double-click that file. It is not Apple Distribution-signed."
