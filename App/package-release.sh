#!/bin/bash
# Build Smart Telescope Sort for:
#   1) Free dual installer (Apple Silicon + Intel, Developer ID signed)
#   2) App Store Connect package (universal, Apple Distribution + installer pkg)
#
# Price: Free. Ready for immediate dual-installer release.
# ASC upload still needs: App record in App Store Connect + Mac App Store
# provisioning profile for com.derry.SmartTelescopeSort (+ optional notary issuer).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/App/Sources"
ICONS="$ROOT/App/Icons"
RESOURCES_SRC="$ROOT/App/Resources"
PLIST_MACOS15="$ROOT/App/Info-macOS15.plist"
ENT_DID="$ROOT/App/Entitlements-DeveloperID.plist"
ENT_MAS="$ROOT/App/Entitlements-AppStore.plist"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
MIN_OS="15.0"
ICON_VARIANT="OS15"
TEAM="JA83U5948W"
BUNDLE_ID="com.derry.SmartTelescopeSort"

DIST_DUAL="$ROOT/Dist/macOS15"
STAGE="$DIST_DUAL/staging/Smart-Telescope-Sort-macOS15-Installer"
PAYLOADS="$STAGE/Payloads"
ZIP_OUT="$DIST_DUAL/Smart-Telescope-Sort-macOS15-Installer.zip"

# Keep in sync with the newest Connect upload. Builds 4-8 are already used.
# Bump MARKETING_VERSION / BUILD_NUMBER together before the next ASC upload.
MARKETING_VERSION="1.2"
BUILD_NUMBER="9"

ASC_OUT="$ROOT/AppStore/Connect-Package-${MARKETING_VERSION}-${BUILD_NUMBER}"
ASC_APP="$ASC_OUT/Smart Telescope Sort.app"
BINS="$ROOT/.build-bins/release"
ASC_PKG="$ASC_OUT/SmartTelescopeSort-${MARKETING_VERSION}.${BUILD_NUMBER}-MacAppStore.pkg"

DID_ID="$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Developer ID Application:/{print $2; exit}')"
DIST_ID="$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Apple Distribution:/{print $2; exit}')"
INSTALLER_ID="$(security find-identity -v 2>/dev/null | awk -F'"' '/3rd Party Mac Developer Installer:/{print $2; exit}')"

SOURCES=(
  "$SRC/TelescopeKind.swift"
  "$SRC/CaptureSorter.swift"
  "$SRC/LibraryFolders.swift"
  "$SRC/AgreementRecord.swift"
  "$SRC/ContentView.swift"
  "$SRC/SmartTelescopeSortApp.swift"
)

if [[ ! -f "$ICONS/AppIcon-${ICON_VARIANT}.icns" ]]; then
  echo "Missing icon: $ICONS/AppIcon-${ICON_VARIANT}.icns" >&2
  exit 1
fi
if [[ ! -f "$RESOURCES_SRC/Smart-Telescope-Sort-User-Manual.pdf" ]]; then
  python3 "$ROOT/App/Scripts/build-user-manual.py"
fi
if [[ -z "$DID_ID" ]]; then
  echo "Missing Developer ID Application identity." >&2
  exit 1
fi
if [[ -z "$DIST_ID" ]]; then
  echo "Missing Apple Distribution identity." >&2
  exit 1
fi
if [[ -z "$INSTALLER_ID" ]]; then
  echo "Missing 3rd Party Mac Developer Installer identity." >&2
  exit 1
fi

compile_arch() {
  local arch="$1"
  local out_bin="$2"
  local target="${arch}-apple-macos${MIN_OS}"
  echo "Compiling $target -> $out_bin"
  mkdir -p "$(dirname "$out_bin")"
  xcrun swiftc \
    -sdk "$SDK" \
    -target "$target" \
    -parse-as-library \
    -O \
    "${SOURCES[@]}" \
    -o "$out_bin" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Foundation
  chmod +x "$out_bin"
}

assemble_app() {
  local app="$1"
  local bin="$2"
  local entitlements="$3"
  local identity="$4"
  local extras=("${@:5}")

  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$PLIST_MACOS15" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$app/Contents/Info.plist"
  cp "$ICONS/AppIcon-${ICON_VARIANT}.icns" "$app/Contents/Resources/AppIcon.icns"
  cp "$RESOURCES_SRC/Smart-Telescope-Sort-User-Manual.pdf" \
    "$app/Contents/Resources/Smart-Telescope-Sort-User-Manual.pdf"
  cp "$RESOURCES_SRC/BigSkyAstro-logo.png" "$app/Contents/Resources/BigSkyAstro-logo.png"
  cp "$RESOURCES_SRC/GitHub-logo.png" "$app/Contents/Resources/GitHub-logo.png"
  cp "$bin" "$app/Contents/MacOS/SmartTelescopeSort"
  chmod +x "$app/Contents/MacOS/SmartTelescopeSort"

  local sign_args=(--force --deep --options runtime --timestamp --entitlements "$entitlements" --sign "$identity")
  if [[ ${#extras[@]} -gt 0 ]]; then
    sign_args+=("${extras[@]}")
  fi
  codesign "${sign_args[@]}" "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
}

echo "=== Dual installer (Developer ID) ==="
rm -rf "$DIST_DUAL/staging"
mkdir -p "$PAYLOADS/arm64" "$PAYLOADS/x86_64" "$BINS"

compile_arch arm64 "$BINS/SmartTelescopeSort-arm64"
compile_arch x86_64 "$BINS/SmartTelescopeSort-x86_64"

assemble_app "$PAYLOADS/arm64/Smart Telescope Sort.app" \
  "$BINS/SmartTelescopeSort-arm64" "$ENT_DID" "$DID_ID"
assemble_app "$PAYLOADS/x86_64/Smart Telescope Sort.app" \
  "$BINS/SmartTelescopeSort-x86_64" "$ENT_DID" "$DID_ID"

HOST_ARCH="$(uname -m)"
HOST_APP="$ROOT/Smart Telescope Sort macOS15.app"
rm -rf "$HOST_APP"
ditto "$PAYLOADS/${HOST_ARCH}/Smart Telescope Sort.app" "$HOST_APP"

cp "$ROOT/App/macos15-installer/Install.command" "$STAGE/Install.command"
cp "$ROOT/App/macos15-installer/README.txt" "$STAGE/README.txt"
cp "$RESOURCES_SRC/Smart-Telescope-Sort-User-Manual.pdf" \
  "$STAGE/Smart-Telescope-Sort-User-Manual.pdf"
chmod +x "$STAGE/Install.command"

# Mark free immediate release in installer README stamp
{
  echo
  echo "Edition: Free"
  echo "Release: Immediate (Developer ID signed dual installer)"
  echo "Built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >> "$STAGE/README.txt"

rm -f "$ZIP_OUT"
(
  cd "$DIST_DUAL/staging"
  ditto -c -k --sequesterRsrc --keepParent "Smart-Telescope-Sort-macOS15-Installer" "$ZIP_OUT"
)

echo "=== App Store Connect package (universal) ==="
rm -rf "$ASC_OUT"
mkdir -p "$ASC_OUT/Images" "$ASC_OUT/Demo Captures"

# Universal binary for Mac App Store
lipo -create \
  "$BINS/SmartTelescopeSort-arm64" \
  "$BINS/SmartTelescopeSort-x86_64" \
  -output "$BINS/SmartTelescopeSort-universal"

# Prefer Mac App Store provisioning profile if present for this bundle ID
PROFILE_EMBED=""
for f in \
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.provisionprofile \
  "$HOME/Library/MobileDevice/Provisioning Profiles/"*.mobileprovision
do
  [[ -f "$f" ]] || continue
  tmp="$BINS/profile-$$.plist"
  if security cms -D -i "$f" -o "$tmp" 2>/dev/null; then
    if plutil -extract Entitlements.xml -- - <"$tmp" >/dev/null 2>&1; then :; fi
    if grep -q "$BUNDLE_ID" "$tmp" 2>/dev/null && grep -qi "Mac App Store\|Distribution\|AppStore" "$tmp" 2>/dev/null; then
      PROFILE_EMBED="$f"
      break
    fi
    if grep -q "$BUNDLE_ID" "$tmp" 2>/dev/null; then
      PROFILE_EMBED="$f"
      break
    fi
  fi
done

assemble_app "$ASC_APP" "$BINS/SmartTelescopeSort-universal" "$ENT_MAS" "$DIST_ID"
xcrun actool "$ROOT/App/Assets.xcassets" --compile "$ASC_APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 15.0 --app-icon AppIcon \
  --output-partial-info-plist "$BINS/actool-partial.plist" >/dev/null
if [[ -n "$PROFILE_EMBED" ]]; then
  echo "Embedding provisioning profile: $PROFILE_EMBED"
  xattr -d com.apple.quarantine "$PROFILE_EMBED" 2>/dev/null || true
  cp "$PROFILE_EMBED" "$ASC_APP/Contents/embedded.provisionprofile"
  xattr -cr "$ASC_APP"
  codesign --force --deep --options runtime --timestamp \
    --identifier "$BUNDLE_ID" \
    --entitlements "$ENT_MAS" --sign "$DIST_ID" "$ASC_APP"
  xattr -cr "$ASC_APP"
else
  echo "NOTE: No Mac App Store provisioning profile found for $BUNDLE_ID."
  echo "      Create the App ID + Mac App Store Distribution profile in developer.apple.com,"
  echo "      download it, re-run this script, then upload the pkg with Transporter."
fi

productbuild \
  --component "$ASC_APP" /Applications \
  --sign "$INSTALLER_ID" \
  "$ASC_PKG"

# Listing + images + demo for review
cp "$ROOT/AppStore/ASC-Listing-Copy.md" "$ASC_OUT/ASC-Listing-Copy.md"
cp "$ROOT/AppStore/Privacy-and-Disclaimer.md" "$ASC_OUT/Privacy-and-Disclaimer.md" 2>/dev/null || true
cp -R "$ROOT/AppStore/Images/." "$ASC_OUT/Images/" 2>/dev/null || true
ditto "$ROOT/Demo Captures" "$ASC_OUT/Demo Captures"

cat > "$ASC_OUT/UPLOAD-NOTES.txt" <<EOF
Smart Telescope Sort — Free — Immediate release package
Version ${MARKETING_VERSION} (${BUILD_NUMBER}) · Bundle ID $BUNDLE_ID · Team $TEAM

Dual installer (email / USB / website):
  $ZIP_OUT

App Store Connect pkg (Transporter / altool):
  $ASC_PKG

ASC fields:
  Price: Free
  Privacy: https://bigskyastro.com/privacy
  Support: https://bigskyastro.com/feedback/smart-telescope-sort
  Marketing: https://bigskyastro.com/macos/smart-telescope-sort

Notes:
  - CFBundleShortVersionString / CFBundleVersion are stamped from MARKETING_VERSION / BUILD_NUMBER in package-release.sh.
  - Next ASC upload: bump BUILD_NUMBER (and Info-macOS15.plist) above the highest build already accepted in Connect.

Built: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

echo
echo "DONE — Free dual installer ready:"
echo "  $ZIP_OUT"
ls -lh "$ZIP_OUT"
echo
echo "ASC package folder:"
echo "  $ASC_OUT"
ls -lh "$ASC_PKG" "$ASC_APP/Contents/MacOS/SmartTelescopeSort"
lipo -archs "$ASC_APP/Contents/MacOS/SmartTelescopeSort"
echo
echo "Payloads:"
find "$STAGE" -name SmartTelescopeSort -type f -print -exec lipo -archs {} \;
