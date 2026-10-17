#!/bin/bash
# Build Telescope Data Sort for macOS 15 — Apple Silicon + Intel —
# then install a developer-signed local test app over the App Store-named bundle.
# Does NOT publish to APP INSTALLS or the App Store.
# A free price does not matter. Apple Distribution plus
# com.apple.application-identifier and com.apple.developer.team-identifier
# is only authorized by a Mac App Store provisioning profile. Double-clicking
# that .app outside an App Store install is killed by AMFI before main:
# "The application can't be opened." Developer-signed local builds are the
# ones that open on this Mac.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=macos-bundle.sh
source "$ROOT/App/macos-bundle.sh"
SRC="$ROOT/App/Sources"
ICONS="$ROOT/App/Icons"
PLIST="$ROOT/App/Info-macOS15.plist"
ENT_LOCAL="$ROOT/App/Entitlements-Local.plist"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
DIST="$ROOT/Dist/macOS15"
STAGE="$DIST/staging/Telescope-Data-Sort-macOS15-Installer"
PAYLOADS="$STAGE/Payloads"
ZIP_OUT="$DIST/Telescope-Data-Sort-macOS15-Installer.zip"
MIN_OS="15.0"
ICON_VARIANT="OS15"
BINS="$ROOT/.build-bins/macos15"

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
if [[ ! -f "$ENT_LOCAL" ]]; then
  echo "Missing $ENT_LOCAL" >&2
  exit 1
fi
if [[ ! -f "$ROOT/App/Resources/Telescope-Data-Sort-User-Manual.pdf" ]]; then
  python3 "$ROOT/App/Scripts/build-user-manual.py"
fi

echo "=== Local test app (developer-signed, this Mac only) ==="
prepare_local_signing "$ENT_LOCAL"

info_plist_ldflags "$PLIST"
rm -rf "$DIST/staging" "$BINS"
mkdir -p "$PAYLOADS/arm64" "$PAYLOADS/x86_64" "$BINS"

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
    "${INFO_PLIST_LDFLAGS[@]}" \
    "${SOURCES[@]}" \
    -o "$bin" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Foundation

  chmod +x "$bin"
  compile_asset_catalog "$app" "$ROOT/App/Assets.xcassets" "$BINS/actool-$arch.plist" "$MIN_OS"
  sign_local_developer "$app" "$ENT_LOCAL"
  echo "  -> $app ($(lipo -archs "$bin" 2>/dev/null || file "$bin"))"
}

build_one arm64
build_one x86_64

HOST_ARCH="$(detect_mac_cpu)"
case "$HOST_ARCH" in
  arm64|x86_64) ;;
  *)
    echo "Unsupported processor: $HOST_ARCH" >&2
    exit 1
    ;;
esac
HOST_APP="$ROOT/Telescope Data Sort macOS15.app"
rm -rf "$HOST_APP"
ditto "$PAYLOADS/${HOST_ARCH}/Telescope Data Sort.app" "$HOST_APP"
xattr -cr "$HOST_APP" 2>/dev/null || true
if ! local_signature_is_developer "$HOST_APP"; then
  sign_local_developer "$HOST_APP" "$ENT_LOCAL"
fi
assert_local_developer "$HOST_APP"
echo "Host smoke copy: $HOST_APP"

install_local_test_app "$PAYLOADS/${HOST_ARCH}/Telescope Data Sort.app" "$ENT_LOCAL" "$ROOT"

cp "$ROOT/App/macos15-installer/Install.command" "$STAGE/Install.command"
cp "$ROOT/App/macos15-installer/README.txt" "$STAGE/README.txt"
cp "$ROOT/App/macos-bundle.sh" "$STAGE/macos-bundle.sh"
cp "$ENT_LOCAL" "$STAGE/Entitlements-Local.plist"
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
echo "Installed local test app (developer-signed): /Applications/$LOCAL_APPSTORE_APP_NAME"
echo "Signing identity: $LOCAL_SIGN_IDENTITY"
echo "Double-click that file. It is not Apple Distribution-signed."
echo
echo "Payloads:"
find "$STAGE" -name SmartTelescopeSort -type f -print -exec lipo -archs {} \;
