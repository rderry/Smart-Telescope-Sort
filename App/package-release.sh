#!/bin/bash
# Local test install for this Mac, plus an optional dual-CPU zip.
#
# The app Rick double-clicks is "Smart Telescope Sort (App Store).app".
# A free price does not matter. Apple Distribution plus
# com.apple.application-identifier and com.apple.developer.team-identifier
# is only authorized by a Mac App Store provisioning profile. Double-clicking
# that .app outside an App Store install is killed by AMFI before main:
# "The application can't be opened." Developer-signed local builds are the
# ones that open on this Mac.
#
# The local app is signed with an Apple Development identity from
# `security find-identity -p codesigning -v`. When several exist, the one
# named on a matching development profile is used; otherwise the first
# Apple Development line is used. If there is none, the script uses Mac
# Developer, then Developer ID Application. It does not sign that app
# ad-hoc, and it does not use Apple Distribution or 3rd Party Mac
# Developer. It does not upload.
#
# application-identifier and team-identifier are added only when a development
# provisioning profile for com.derry.SmartTelescopeSort lists this Mac and the
# same Apple Development certificate. Otherwise the local app uses
# Entitlements-Local.plist (sandbox, user-selected read-write, bookmarks,
# network.client) and no profile. A distribution profile paired with a
# development certificate, or a development profile paired with Apple
# Distribution, is the can't-be-opened failure and is not used here.
#
# An App Store Connect package is written only when Apple Distribution, the
# 3rd Party Mac Developer Installer identity, and a Mac App Store distribution
# profile are all present. That package lives under AppStore/Connect-Upload-Only-*
# and is not installed. Missing any of those does not fail the local install.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=macos-bundle.sh
source "$ROOT/App/macos-bundle.sh"

SRC="$ROOT/App/Sources"
ICONS="$ROOT/App/Icons"
RESOURCES_SRC="$ROOT/App/Resources"
PLIST_MACOS15="$ROOT/App/Info-macOS15.plist"
ENT_LOCAL="$ROOT/App/Entitlements-Local.plist"
ENT_MAS="$ROOT/App/Entitlements-AppStore.plist"
ASSETS="$ROOT/App/Assets.xcassets"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
MIN_OS="15.0"
ICON_VARIANT="OS15"
TEAM="JA83U5948W"
BUNDLE_ID="com.derry.SmartTelescopeSort"

DIST_DUAL="$ROOT/Dist/macOS15"
STAGE="$DIST_DUAL/staging/Telescope-Data-Sort-macOS15-Installer"
PAYLOADS="$STAGE/Payloads"
ZIP_OUT="$DIST_DUAL/Telescope-Data-Sort-macOS15-Installer.zip"

# Keep in sync with the newest Connect upload. Builds 4-9 are uploaded; 10 was a local build only.
# 1.2 (9) is live on the App Store, so the next upload is 1.2.1.
MARKETING_VERSION="1.2.1"
BUILD_NUMBER="11"

# Previous runs wrote a Distribution-signed app here. Remove it so it is not what gets double-clicked.
OLD_ASC_OUT="$ROOT/AppStore/Connect-Package-${MARKETING_VERSION}-${BUILD_NUMBER}"
ASC_OUT="$ROOT/AppStore/Connect-Upload-Only-${MARKETING_VERSION}-${BUILD_NUMBER}"
ASC_APP="$ASC_OUT/MacAppStore-payload/Telescope Data Sort.app"
BINS="$ROOT/.build-bins/release"
ASC_PKG="$ASC_OUT/TelescopeDataSort-${MARKETING_VERSION}.${BUILD_NUMBER}-MacAppStore.pkg"
LOCAL_APP="$BINS/local/$LOCAL_APPSTORE_APP_NAME"
STAMPED_PLIST="$BINS/Info-linked.plist"

DIST_ID="$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Apple Distribution:/{print $2; exit}' || true)"
INSTALLER_ID="$(security find-identity -v 2>/dev/null | awk -F'"' '/3rd Party Mac Developer Installer:/{print $2; exit}' || true)"

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
if [[ ! -f "$ENT_LOCAL" ]]; then
  echo "Missing $ENT_LOCAL" >&2
  exit 1
fi
echo "=== Local test app (developer-signed, this Mac only) ==="
prepare_local_signing "$ENT_LOCAL"
if [[ ! -f "$RESOURCES_SRC/Telescope-Data-Sort-User-Manual.pdf" ]]; then
  python3 "$ROOT/App/Scripts/build-user-manual.py"
fi

rm -rf "$BINS" "$OLD_ASC_OUT" "$ASC_OUT"
mkdir -p "$BINS"
cp "$PLIST_MACOS15" "$STAMPED_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$STAMPED_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$STAMPED_PLIST"
info_plist_ldflags "$STAMPED_PLIST"

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
    "${INFO_PLIST_LDFLAGS[@]}" \
    "${SOURCES[@]}" \
    -o "$out_bin" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Foundation
  chmod +x "$out_bin"
}

# Copy resources and compile Assets.car. Does not sign.
stage_app() {
  local app="$1"
  local bin="$2"
  local partial="$3"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$STAMPED_PLIST" "$app/Contents/Info.plist"
  cp "$ICONS/AppIcon-${ICON_VARIANT}.icns" "$app/Contents/Resources/AppIcon.icns"
  cp "$RESOURCES_SRC/Telescope-Data-Sort-User-Manual.pdf" \
    "$app/Contents/Resources/Telescope-Data-Sort-User-Manual.pdf"
  cp "$RESOURCES_SRC/BigSkyAstro-logo.png" "$app/Contents/Resources/BigSkyAstro-logo.png"
  cp "$RESOURCES_SRC/GitHub-logo.png" "$app/Contents/Resources/GitHub-logo.png"
  cp "$bin" "$app/Contents/MacOS/SmartTelescopeSort"
  chmod +x "$app/Contents/MacOS/SmartTelescopeSort"
  compile_asset_catalog "$app" "$ASSETS" "$partial" "$MIN_OS"
}

compile_arch arm64 "$BINS/SmartTelescopeSort-arm64"
compile_arch x86_64 "$BINS/SmartTelescopeSort-x86_64"
mkdir -p "$(dirname "$LOCAL_APP")"
lipo -create \
  "$BINS/SmartTelescopeSort-arm64" \
  "$BINS/SmartTelescopeSort-x86_64" \
  -output "$BINS/SmartTelescopeSort-universal"
stage_app "$LOCAL_APP" "$BINS/SmartTelescopeSort-universal" "$BINS/actool-local.plist"
sign_local_developer "$LOCAL_APP" "$ENT_LOCAL"

install_local_test_app "$LOCAL_APP" "$ENT_LOCAL" "$ROOT"
echo "Replaced /Applications/${LOCAL_APPSTORE_APP_NAME} with a developer-signed local test app."
echo "Signing identity: $LOCAL_SIGN_IDENTITY"

HOST_SMOKE="$ROOT/Telescope Data Sort macOS15.app"
rm -rf "$HOST_SMOKE"
ditto "$LOCAL_APP" "$HOST_SMOKE"
xattr -cr "$HOST_SMOKE" 2>/dev/null || true
if ! local_signature_is_developer "$HOST_SMOKE"; then
  sign_local_developer "$HOST_SMOKE" "$ENT_LOCAL"
fi

echo "=== Dual installer ==="
build_dual_zip() {
  local arch app
  rm -rf "$DIST_DUAL/staging"
  mkdir -p "$PAYLOADS/arm64" "$PAYLOADS/x86_64"
  for arch in arm64 x86_64; do
    app="$PAYLOADS/$arch/Telescope Data Sort.app"
    stage_app "$app" "$BINS/SmartTelescopeSort-$arch" "$BINS/actool-$arch.plist"
    sign_local_developer "$app" "$ENT_LOCAL"
  done
  cp "$ROOT/App/macos15-installer/Install.command" "$STAGE/Install.command"
  cp "$ROOT/App/macos15-installer/README.txt" "$STAGE/README.txt"
  cp "$ROOT/App/macos-bundle.sh" "$STAGE/macos-bundle.sh"
  cp "$ENT_LOCAL" "$STAGE/Entitlements-Local.plist"
  cp "$RESOURCES_SRC/Telescope-Data-Sort-User-Manual.pdf" \
    "$STAGE/Telescope-Data-Sort-User-Manual.pdf"
  chmod +x "$STAGE/Install.command"
  {
    echo
    echo "Edition: Free"
    echo "Local test: developer-signed sandbox build replaces \"Smart Telescope Sort (App Store).app\" in /Applications."
    echo "Signing identity: $LOCAL_SIGN_IDENTITY"
    echo "Zip payloads use that same identity. Install.command installs those copies locally and does not upload."
    echo "Built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >> "$STAGE/README.txt"
  rm -f "$ZIP_OUT"
  (
    cd "$DIST_DUAL/staging"
    ditto -c -k --sequesterRsrc --keepParent "Telescope-Data-Sort-macOS15-Installer" "$ZIP_OUT"
  )
}

# Keep set -e inside the optional steps. `cmd || warn` would turn it off for the whole function.
run_optional() {
  local label="$1"
  shift
  set +e
  (
    set -euo pipefail
    "$@"
  )
  local status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    echo "WARNING: $label failed (exit $status). The local test app in /Applications is already installed. Nothing was uploaded." >&2
  fi
}
run_optional "dual installer zip" build_dual_zip

# Mac App Store distribution profiles do not list ProvisionedDevices (that is development / Ad Hoc)
# and are not enterprise (ProvisionsAllDevices). A development profile paired with Apple Distribution
# is rejected: that mismatch is the AMFI launch failure.
find_mas_distribution_profile() {
  local f tmp app_id all
  for f in \
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.provisionprofile \
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.mobileprovision \
    "$HOME/Library/MobileDevice/Provisioning Profiles/"*.provisionprofile \
    "$HOME/Library/MobileDevice/Provisioning Profiles/"*.mobileprovision
  do
    [[ -f "$f" ]] || continue
    tmp="$(mktemp /tmp/sts-profile.XXXXXX)"
    if ! security cms -D -i "$f" -o "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      continue
    fi
    app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$tmp" 2>/dev/null || true)"
    if [[ "$app_id" != "$TEAM.$BUNDLE_ID" ]]; then
      rm -f "$tmp"
      continue
    fi
    if /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$tmp" >/dev/null 2>&1; then
      rm -f "$tmp"
      continue
    fi
    all="$(/usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$tmp" 2>/dev/null || true)"
    rm -f "$tmp"
    if [[ "$all" == "true" ]]; then
      continue
    fi
    printf '%s\n' "$f"
    return 0
  done
  return 1
}

build_asc_upload_only() {
  local profile
  if [[ -z "$DIST_ID" || -z "$INSTALLER_ID" ]]; then
    echo "App Store Connect package skipped (Apple Distribution or 3rd Party Mac Developer Installer identity missing)."
    echo "The local test install does not need either identity, and nothing was uploaded."
    return 0
  fi
  profile="$(find_mas_distribution_profile || true)"
  if [[ -z "$profile" ]]; then
    echo "App Store Connect package skipped (no Mac App Store distribution profile for $TEAM.$BUNDLE_ID)."
    echo "Development profiles are not used. The local test install does not need a profile, and nothing was uploaded."
    return 0
  fi
  echo "=== App Store Connect upload-only package ==="
  echo "This app is not installed and is not the file to double-click."
  rm -rf "$ASC_OUT"
  mkdir -p "$(dirname "$ASC_APP")" "$ASC_OUT/Images" "$ASC_OUT/Demo Captures"
  stage_app "$ASC_APP" "$BINS/SmartTelescopeSort-universal" "$BINS/actool-asc.plist"
  xattr -d com.apple.quarantine "$profile" 2>/dev/null || true
  cp "$profile" "$ASC_APP/Contents/embedded.provisionprofile"
  xattr -cr "$ASC_APP" 2>/dev/null || true
  # Sign once, after Assets.car and the profile are both in the bundle. No --deep.
  codesign --force --options runtime --timestamp \
    --identifier "$BUNDLE_ID" \
    --entitlements "$ENT_MAS" \
    --sign "$DIST_ID" \
    "$ASC_APP"
  codesign --verify --strict --verbose=2 "$ASC_APP"
  productbuild \
    --component "$ASC_APP" /Applications \
    --sign "$INSTALLER_ID" \
    "$ASC_PKG"
  if [[ -f "$ROOT/AppStore/ASC-Listing-Copy.md" ]]; then
    cp "$ROOT/AppStore/ASC-Listing-Copy.md" "$ASC_OUT/ASC-Listing-Copy.md"
  fi
  if [[ -f "$ROOT/AppStore/Privacy-and-Disclaimer.md" ]]; then
    cp "$ROOT/AppStore/Privacy-and-Disclaimer.md" "$ASC_OUT/Privacy-and-Disclaimer.md"
  fi
  if [[ -d "$ROOT/AppStore/Images" ]]; then
    cp -R "$ROOT/AppStore/Images/." "$ASC_OUT/Images/"
  fi
  if [[ -d "$ROOT/Demo Captures" ]]; then
    ditto "$ROOT/Demo Captures" "$ASC_OUT/Demo Captures"
  fi
  cat > "$ASC_OUT/UPLOAD-NOTES.txt" <<EOF
Telescope Data Sort — App Store Connect upload-only package
Version ${MARKETING_VERSION} (${BUILD_NUMBER}) · Bundle ID $BUNDLE_ID · Team $TEAM

This folder is not the local test install. Do not double-click MacAppStore-payload.
That payload is Apple Distribution-signed and only launches after App Store installation.
Nothing in this folder was copied to /Applications. This script did not upload it.

Pkg (Transporter, when you choose to upload later):
  $ASC_PKG

The app to double-click on this Mac is:
  /Applications/${LOCAL_APPSTORE_APP_NAME}

Built: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  echo "Upload-only pkg (not installed): $ASC_PKG"
}

run_optional "App Store Connect package" build_asc_upload_only

echo
echo "DONE — local test install (developer-signed, not Apple Distribution):"
echo "  Signing identity: $LOCAL_SIGN_IDENTITY"
echo "  /Applications/$LOCAL_APPSTORE_APP_NAME"
echo "  /Applications/$LOCAL_TELESCOPE_APP_NAME"
if [[ -n "$LOCAL_SIGN_PROFILE" ]]; then
  echo "  Development profile embedded for $LOCAL_APP_IDENTIFIER."
else
  echo "  No provisioning profile embedded."
  echo "  Entitlements: sandbox, user-selected read-write, bookmarks, network.client."
fi
codesign -dv "/Applications/$LOCAL_APPSTORE_APP_NAME" 2>&1 | awk -F= '/^Signature=|^Identifier=|^TeamIdentifier=|^Authority=/{print}'
echo
echo "On this Mac, rebuild and reinstall with:"
printf '  %q/App/package-release.sh\n' "$ROOT"
echo
echo "Double-click \"/Applications/$LOCAL_APPSTORE_APP_NAME\"."
if [[ -f "$ZIP_OUT" ]]; then
  echo "Optional installer zip (Install.command also replaces that filename):"
  echo "  $ZIP_OUT"
fi
