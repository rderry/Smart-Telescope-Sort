#!/bin/bash
# Builds a screenshot-only copy of the app (-D SCREENSHOTS, separate bundle ID so real settings are untouched),
# stages demo folders on the Large Drive scratch area, and captures 2880x1800 screenshots.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../macos-bundle.sh
source "$ROOT/App/macos-bundle.sh"
SRC="$ROOT/App/Sources"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/App/Info-macOS15.plist")"
OUT="$ROOT/AppStore/Images/$VERSION"
SCRATCH="/Volumes/Large Drive/Scratch/sts-shots"
APP="$SCRATCH/Telescope Data Sort.app"
DEMO="/Volumes/Large Drive/Scratch/Astronomy"
FRAME="$SCRATCH/frame.txt"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$SCRATCH" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT"
cp "$ROOT/App/Info-macOS15.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.derry.SmartTelescopeSort.screenshots" "$APP/Contents/Info.plist"
cp "$ROOT/App/Icons/AppIcon.icns" "$ROOT/App/Resources/BigSkyAstro-logo.png" "$ROOT/App/Resources/GitHub-logo.png" "$APP/Contents/Resources/"
info_plist_ldflags "$APP/Contents/Info.plist"
xcrun swiftc -sdk "$SDK" -target "$(uname -m)-apple-macos15.0" -parse-as-library -O -D SCREENSHOTS \
  "${INFO_PLIST_LDFLAGS[@]}" \
  "$SRC"/*.swift "$ROOT/App/Screenshots/ScreenshotMode.swift" \
  -o "$APP/Contents/MacOS/SmartTelescopeSort" -framework SwiftUI -framework AppKit -framework IOKit
compile_asset_catalog "$APP" "$ROOT/App/Assets.xcassets" "$SCRATCH/actool-partial.plist" "15.0"
sign_adhoc_plain "$APP"

stage_captures() {
  rm -rf "$DEMO/Captures"
  ditto "$ROOT/Demo Captures/$1" "$DEMO/Captures"
}
rm -rf "$DEMO" && mkdir -p "$DEMO/Targets/Targets 2026" "$DEMO/Sort Backup"

# A 1440x900 window captures at 2880x1800 on Retina; it only fits above the Dock while the Dock auto-hides.
DOCK_AUTOHIDE=$(defaults read com.apple.dock autohide 2>/dev/null || echo 0)
restore_dock() {
  if [[ "$DOCK_AUTOHIDE" != "1" ]]; then
    defaults write com.apple.dock autohide -bool false && killall Dock
  fi
}
trap restore_dock EXIT
if [[ "$DOCK_AUTOHIDE" != "1" ]]; then
  defaults write com.apple.dock autohide -bool true && killall Dock && sleep 2
fi

shot() {
  local name="$1"; shift
  rm -f "$FRAME"
  env STS_CAPTURES="$DEMO/Captures" STS_ORIGINALS="$DEMO/Targets" STS_BACKUP="$DEMO/Sort Backup" \
    STS_FRAME="{{36,30},{1440,900}}" STS_FRAME_FILE="$FRAME" "$@" \
    "$APP/Contents/MacOS/SmartTelescopeSort" >"$SCRATCH/shot.log" 2>&1 &
  local pid=$!
  sleep 4.5
  screencapture -x -R "$(cat "$FRAME")" "$OUT/$name.png"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo "$name $(sips -g pixelWidth -g pixelHeight "$OUT/$name.png" | awk '/pixel/{printf "%s ", $2}')"
}

stage_captures Vaonis
shot 01-main STS_SHOT=main STS_TYPES=tiff,fits STS_FORMAT=tarball
shot 02-review-file-plan STS_SHOT=plan STS_TYPES=tiff,fits STS_FORMAT=tarball
shot 03-copy-check-delete STS_SHOT=copy STS_TYPES=tiff,fits STS_FORMAT=tarball
shot 04-backup-progress STS_SHOT=backup STS_TYPES=tiff,fits STS_FORMAT=tarball
shot 05-first-launch-terms STS_SHOT=terms STS_TYPES=tiff,fits STS_FORMAT=tarball
shot 06-finished-folder STS_SHOT=finished STS_TYPES=tiff,fits STS_FORMAT=tarball
shot 07-open-source STS_SHOT=credit STS_TYPES=tiff,fits STS_FORMAT=tarball
stage_captures Seestar
shot 08-object-albums STS_SHOT=main STS_TYPES=tiff,fits,jpeg STS_FORMAT=zip

rm -rf "$DEMO" "$SCRATCH"
defaults delete com.derry.SmartTelescopeSort.screenshots >/dev/null 2>&1 || true
echo "Screenshots in $OUT"
