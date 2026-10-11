#!/bin/bash
# Build Telescope Data Sort for macOS 15 — Apple Silicon + Intel —
# then pack a zip whose installer picks the matching CPU.
# Does NOT publish to APP INSTALLS (hold for review).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/App/Sources"
ICONS="$ROOT/App/Icons"
PLIST="$ROOT/App/Info-macOS15.plist"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
DIST="$ROOT/Dist/macOS15"
STAGE="$DIST/staging/Telescope-Data-Sort-macOS15-Installer"
PAYLOADS="$STAGE/Payloads"
ZIP_OUT="$DIST/Telescope-Data-Sort-macOS15-Installer.zip"
MIN_OS="15.0"
ICON_VARIANT="OS15"

SOURCES=(
  "$SRC/TelescopeKind.swift"
  "$SRC/CaptureSorter.swift"
  "$SRC/LibraryFolders.swift"
  "$SRC/AgreementRecord.swift"
  "$SRC/Credits.swift"
  "$SRC/CreditsView.swift"
  "$SRC/ContentView.swift"
  "$SRC/SmartTelescopeSortApp.swift"
)

if [[ ! -f "$ICONS/AppIcon-${ICON_VARIANT}.icns" ]]; then
  echo "Missing icon: $ICONS/AppIcon-${ICON_VARIANT}.icns" >&2
  exit 1
fi
if [[ ! -f "$PLIST" ]]; then
  echo "Missing $PLIST" >&2
  exit 1
fi
if [[ ! -f "$ROOT/App/Resources/Telescope-Data-Sort-User-Manual.pdf" ]]; then
  python3 "$ROOT/App/Scripts/build-user-manual.py"
fi

build_one() {
  local arch="$1"
  local target="${arch}-apple-macos${MIN_OS}"
  local app="$PAYLOADS/${arch}/Telescope Data Sort.app"
  local macos="$app/Contents/MacOS"
  local resources="$app/Contents/Resources"
  local bin="$macos/SmartTelescopeSort"

  rm -rf "$app"
  mkdir -p "$macos" "$resources"
  cp "$PLIST" "$app/Contents/Info.plist"
  cp "$ICONS/AppIcon-${ICON_VARIANT}.icns" "$resources/AppIcon.icns"
  cp "$ROOT/App/Resources/Telescope-Data-Sort-User-Manual.pdf" \
    "$resources/Telescope-Data-Sort-User-Manual.pdf"
  cp "$ROOT/App/Resources/BigSkyAstro-logo.png" "$resources/BigSkyAstro-logo.png"
  cp "$ROOT/App/Resources/GitHub-logo.png" "$resources/GitHub-logo.png"

  echo "Compiling $target..."
  xcrun swiftc \
    -sdk "$SDK" \
    -target "$target" \
    -parse-as-library \
    -O \
    "${SOURCES[@]}" \
    -o "$bin" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Foundation

  chmod +x "$bin"
  codesign --force --deep --sign - "$app" >/dev/null 2>&1 || true
  echo "  -> $app ($(lipo -archs "$bin" 2>/dev/null || file "$bin"))"
}

rm -rf "$DIST/staging"
mkdir -p "$PAYLOADS/arm64" "$PAYLOADS/x86_64"

build_one arm64
build_one x86_64

HOST_ARCH="$(uname -m)"
HOST_APP="$ROOT/Telescope Data Sort macOS15.app"
rm -rf "$HOST_APP"
ditto "$PAYLOADS/${HOST_ARCH}/Telescope Data Sort.app" "$HOST_APP"
echo "Host smoke copy: $HOST_APP"

cp "$ROOT/App/macos15-installer/Install.command" "$STAGE/Install.command"
cp "$ROOT/App/macos15-installer/README.txt" "$STAGE/README.txt"
cp "$ROOT/App/Resources/Telescope-Data-Sort-User-Manual.pdf" \
  "$STAGE/Telescope-Data-Sort-User-Manual.pdf"
chmod +x "$STAGE/Install.command"

rm -f "$ZIP_OUT"
(
  cd "$DIST/staging"
  if command -v ditto >/dev/null; then
    ditto -c -k --sequesterRsrc --keepParent "Telescope-Data-Sort-macOS15-Installer" "$ZIP_OUT"
  else
    zip -r -X "$ZIP_OUT" "Telescope-Data-Sort-macOS15-Installer"
  fi
)

echo
echo "HOLD — local Dist only (not published to APP INSTALLS / App Store):"
echo "  $ZIP_OUT"
ls -lh "$ZIP_OUT"
echo
echo "Payloads:"
find "$STAGE" -name SmartTelescopeSort -type f -print -exec lipo -archs {} \;
