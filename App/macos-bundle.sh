#!/bin/bash
# Shared Mac bundle helpers. Source from the build scripts; do not execute.
# Targets the bash 3.2 that ships with macOS.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "Source App/macos-bundle.sh from a build script." >&2
  exit 1
fi

# Filename Finder shows in "The application \"…\" can't be opened."
LOCAL_APPSTORE_APP_NAME="Smart Telescope Sort (App Store).app"
LOCAL_TELESCOPE_APP_NAME="Telescope Data Sort.app"

# Linker flags that embed Info.plist in the Mach-O (__TEXT,__info_plist).
# Newer macOS refuses a bundle whose executable has no embedded Info.plist.
# Sets the global array INFO_PLIST_LDFLAGS. The plist path may contain spaces.
info_plist_ldflags() {
  INFO_PLIST_LDFLAGS=(
    -Xlinker -sectcreate
    -Xlinker __TEXT
    -Xlinker __info_plist
    -Xlinker "$1"
  )
}

detect_mac_cpu() {
  local hw_arm translated uname_m
  hw_arm="$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)"
  if [[ "$hw_arm" == "1" ]]; then
    echo "arm64"
    return 0
  fi
  translated="$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)"
  if [[ "$translated" == "1" ]]; then
    echo "arm64"
    return 0
  fi
  uname_m="$(uname -m)"
  case "$uname_m" in
    arm64) echo "arm64" ;;
    x86_64|i386|i686) echo "x86_64" ;;
    *) echo "unknown:$uname_m" ;;
  esac
}

# Compile Assets.car into the bundle. Call this before codesign.
# The partial plist is written outside the bundle so it is not sealed in late.
compile_asset_catalog() {
  local app="$1"
  local assets="$2"
  local partial_plist="$3"
  local min_os="${4:-15.0}"
  mkdir -p "$app/Contents/Resources" "$(dirname "$partial_plist")"
  xcrun actool "$assets" \
    --compile "$app/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target "$min_os" \
    --app-icon AppIcon \
    --output-partial-info-plist "$partial_plist"
}

reject_profile_entitlements() {
  local entitlements="$1"
  if grep -q "com.apple.application-identifier" "$entitlements"; then
    echo "Refusing local sign: $entitlements contains com.apple.application-identifier (needs a provisioning profile)." >&2
    return 1
  fi
  if grep -q "com.apple.developer.team-identifier" "$entitlements"; then
    echo "Refusing local sign: $entitlements contains com.apple.developer.team-identifier (needs a provisioning profile)." >&2
    return 1
  fi
}

# Confirm the bundle is ad-hoc and does not carry profile-only entitlements.
assert_local_adhoc() {
  local app="$1"
  local dumped sig
  codesign --verify --strict --verbose=2 "$app"
  dumped="$(codesign -d --entitlements :- "$app" 2>/dev/null || true)"
  if grep -q "com.apple.application-identifier" <<<"$dumped"; then
    echo "Local app still has com.apple.application-identifier: $app" >&2
    return 1
  fi
  if grep -q "com.apple.developer.team-identifier" <<<"$dumped"; then
    echo "Local app still has com.apple.developer.team-identifier: $app" >&2
    return 1
  fi
  sig="$(codesign -dv "$app" 2>&1 || true)"
  if grep -E -q "Authority=(Apple Distribution|3rd Party Mac Developer|Apple Development|Developer ID Application)" <<<"$sig"; then
    echo "Local test app must not use an Apple signing identity: $app" >&2
    printf '%s\n' "$sig" >&2
    return 1
  fi
  if ! grep -q "Signature=adhoc" <<<"$sig" && ! grep -q "flags=0x2(adhoc)" <<<"$sig"; then
    echo "Local test app is not ad-hoc signed: $app" >&2
    printf '%s\n' "$sig" >&2
    return 1
  fi
  if grep -q "^TeamIdentifier=" <<<"$sig" && ! grep -q "^TeamIdentifier=not set" <<<"$sig"; then
    echo "Local test app has a team identifier; AMFI will require a matching profile: $app" >&2
    printf '%s\n' "$sig" >&2
    return 1
  fi
}

# Ad-hoc signature applied only after every file (including Assets.car) is in the bundle.
# No --deep: Apple documents that --deep produces a bad bundle seal.
sign_local_adhoc() {
  local app="$1"
  local entitlements="$2"
  if [[ ! -d "$app" ]]; then
    echo "Not an app bundle: $app" >&2
    return 1
  fi
  if [[ ! -f "$entitlements" ]]; then
    echo "Missing entitlements: $entitlements" >&2
    return 1
  fi
  if [[ ! -x "$app/Contents/MacOS/SmartTelescopeSort" ]]; then
    echo "Missing executable: $app/Contents/MacOS/SmartTelescopeSort" >&2
    return 1
  fi
  reject_profile_entitlements "$entitlements"
  rm -f "$app/Contents/embedded.provisionprofile"
  xattr -cr "$app" 2>/dev/null || true
  chmod +x "$app/Contents/MacOS/SmartTelescopeSort"
  codesign --force --sign - --entitlements "$entitlements" "$app"
  assert_local_adhoc "$app"
}

sign_adhoc_plain() {
  local app="$1"
  if [[ ! -d "$app" ]]; then
    echo "Not an app bundle: $app" >&2
    return 1
  fi
  rm -f "$app/Contents/embedded.provisionprofile"
  xattr -cr "$app" 2>/dev/null || true
  codesign --force --sign - "$app"
  assert_local_adhoc "$app"
}

register_app() {
  local app="$1"
  local ls="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  touch "$app" 2>/dev/null || true
  if [[ -x "$ls" ]]; then
    "$ls" -f "$app" >/dev/null 2>&1 || true
  fi
}

# Copy src onto dest, then ad-hoc sign the installed bytes (after quarantine is cleared).
install_one_local_app() {
  local src="$1"
  local dest="$2"
  local entitlements="$3"
  local parent script
  if [[ ! -d "$src" ]]; then
    echo "Missing app to install: $src" >&2
    return 1
  fi
  case "$dest" in
    "$src"|"$src"/*)
      return 0
      ;;
  esac
  case "$src" in
    "$dest"/*)
      echo "Refusing to copy $src onto $dest (source is inside the destination)." >&2
      return 1
      ;;
  esac
  parent="$(dirname "$dest")"
  if [[ ! -d "$parent" ]]; then
    echo "Install directory does not exist: $parent" >&2
    return 1
  fi
  echo "Installing local test app -> $dest"
  script="$(mktemp /tmp/sts-install.XXXXXX)"
  cat > "$script" <<EOF
#!/bin/bash
set -euo pipefail
rm -rf $(printf '%q' "$dest")
ditto $(printf '%q' "$src") $(printf '%q' "$dest")
xattr -cr $(printf '%q' "$dest") || true
chmod +x $(printf '%q' "$dest/Contents/MacOS/SmartTelescopeSort")
rm -f $(printf '%q' "$dest/Contents/embedded.provisionprofile")
codesign --force --sign - --entitlements $(printf '%q' "$entitlements") $(printf '%q' "$dest")
codesign --verify --strict --verbose=2 $(printf '%q' "$dest")
EOF
  chmod +x "$script"
  if [[ -w "$parent" && ( ! -e "$dest" || -w "$dest" ) ]]; then
    if ! /bin/bash "$script"; then
      echo "Could not write $dest as the current user. Requesting administrator privileges."
      osascript -e "do shell script \"/bin/bash $(printf '%q' "$script")\" with administrator privileges"
    fi
  else
    echo "Requesting administrator privileges to write $parent"
    osascript -e "do shell script \"/bin/bash $(printf '%q' "$script")\" with administrator privileges"
  fi
  rm -f "$script"
  assert_local_adhoc "$dest"
  register_app "$dest"
}

# Always replace the bundle Rick is double-clicking, plus Telescope Data Sort.app.
install_local_test_app() {
  local src="$1"
  local entitlements="$2"
  local root_dir="${3:-}"
  local host installed bin

  reject_profile_entitlements "$entitlements"
  install_one_local_app "$src" "/Applications/$LOCAL_APPSTORE_APP_NAME" "$entitlements"
  install_one_local_app "$src" "/Applications/$LOCAL_TELESCOPE_APP_NAME" "$entitlements"

  bin="/Applications/$LOCAL_APPSTORE_APP_NAME/Contents/MacOS/SmartTelescopeSort"
  host="$(detect_mac_cpu)"
  installed="$(lipo -archs "$bin" 2>/dev/null || true)"
  case "$host" in
    arm64|x86_64) ;;
    *)
      echo "Unsupported processor: $host" >&2
      return 1
      ;;
  esac
  if [[ "$installed" != *"$host"* ]]; then
    echo "Installed binary ($installed) does not include this Mac ($host): $bin" >&2
    return 1
  fi

  replace_existing_named "$src" "$entitlements" "$HOME/Applications"
  replace_existing_named "$src" "$entitlements" "$HOME/Desktop"
  replace_existing_named "$src" "$entitlements" "$HOME/Downloads"
  if [[ -n "$root_dir" ]]; then
    replace_existing_named "$src" "$entitlements" "$root_dir"
    # Build product with the filename Finder shows, next to the project.
    install_one_local_app "$src" "$root_dir/$LOCAL_APPSTORE_APP_NAME" "$entitlements"
  fi
}

# Replace an already-present "Smart Telescope Sort (App Store).app" under dir.
# Does not create one when it is absent (install_local_test_app creates /Applications).
replace_existing_named() {
  local src="$1"
  local entitlements="$2"
  local dir="$3"
  local found
  local list
  [[ -d "$dir" ]] || return 0
  list="$(mktemp /tmp/sts-apps.XXXXXX)"
  find "$dir" -name "$LOCAL_APPSTORE_APP_NAME" -type d -prune -print >"$list" 2>/dev/null || true
  while IFS= read -r found; do
    [[ -n "$found" ]] || continue
    [[ "$found" == "/Applications/$LOCAL_APPSTORE_APP_NAME" ]] && continue
    [[ "$found" == "$src" ]] && continue
    case "$found" in
      */.build-bins/*|*/MacAppStore-payload/*) continue ;;
    esac
    install_one_local_app "$src" "$found" "$entitlements"
  done <"$list"
  rm -f "$list"
}
