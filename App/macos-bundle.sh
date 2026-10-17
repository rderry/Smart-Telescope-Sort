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

# A free price does not matter. Apple Distribution plus
# com.apple.application-identifier and com.apple.developer.team-identifier
# is only authorized by a Mac App Store provisioning profile. Double-clicking
# that .app outside an App Store install is killed by AMFI before main:
# "The application can't be opened." Developer-signed local builds are the
# ones that open on this Mac. The local install therefore signs with Apple
# Development (then Mac Developer, then Developer ID Application). It does
# not sign that app with Apple Distribution, 3rd Party Mac Developer, or an
# ad-hoc signature.
LOCAL_TEAM_ID="JA83U5948W"
LOCAL_BUNDLE_ID="com.derry.SmartTelescopeSort"
LOCAL_APP_IDENTIFIER="${LOCAL_TEAM_ID}.${LOCAL_BUNDLE_ID}"

LOCAL_SIGN_IDENTITY=""
LOCAL_SIGN_HASH=""
LOCAL_SIGN_ENTITLEMENTS=""
LOCAL_SIGN_PROFILE=""
_LOCAL_SIGN_READY=0
_LOCAL_SIGN_SAFE=""

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
    echo "Refusing local sign: $entitlements contains com.apple.application-identifier (needs a matching development profile)." >&2
    return 1
  fi
  if grep -q "com.apple.developer.team-identifier" "$entitlements"; then
    echo "Refusing local sign: $entitlements contains com.apple.developer.team-identifier (needs a matching development profile)." >&2
    return 1
  fi
}

# stdin: `security find-identity -p codesigning -v` text.
# stdout: one "HASH<TAB>NAME" for the preferred local identity.
# Preference is Apple Development, then Mac Developer, then Developer ID
# Application. Apple Distribution and 3rd Party Mac Developer are ignored.
# The first line of the winning prefix is kept.
pick_local_signing_record() {
  awk -F'"' '
    function rank_of(name) {
      if (index(name, "Apple Development:") == 1) return 1
      if (index(name, "Mac Developer:") == 1) return 2
      if (index(name, "Developer ID Application:") == 1) return 3
      return 0
    }
    function hash_of(prefix_field,    line) {
      line = prefix_field
      sub(/^.*\)[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      return line
    }
    BEGIN { chosen_rank = 0 }
    NF >= 2 {
      r = rank_of($2)
      if (r > 0 && (chosen_rank == 0 || r < chosen_rank)) {
        chosen_rank = r
        chosen_name = $2
        chosen_hash = hash_of($1)
      }
    }
    END {
      if (chosen_rank > 0) print chosen_hash "\t" chosen_name
    }
  '
}

# stdin: find-identity text. $1 is a name prefix including the colon.
# stdout: "HASH<TAB>NAME" for every match, in keychain order.
list_identity_records() {
  local prefix="$1"
  awk -F'"' -v prefix="$prefix" '
    function hash_of(prefix_field,    line) {
      line = prefix_field
      sub(/^.*\)[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      return line
    }
    NF >= 2 && index($2, prefix) == 1 {
      print hash_of($1) "\t" $2
    }
  '
}

valid_identity_hash() {
  local hash="$1"
  [[ "$hash" =~ ^[0-9A-Fa-f]{40}$ || "$hash" =~ ^[0-9A-Fa-f]{64}$ ]]
}

local_mac_hardware_uuid() {
  local uuid
  uuid="$(ioreg -d2 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/{print $4; exit}' || true)"
  if [[ -z "$uuid" ]]; then
    uuid="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Hardware UUID/{gsub(/^ +| +$/, "", $2); print $2; exit}' || true)"
  fi
  if [[ "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    printf '%s\n' "$uuid"
    return 0
  fi
  return 1
}

# Exit 0 only when the decoded profile is a development profile for this
# bundle, authorizes the sandbox set, lists this Mac, and was issued for
# the certificate SHA-1 (or SHA-256) in argument 2. Anything uncertain
# exits 1 so the caller omits the profile.
profile_matches_development_cert() {
  local plist="$1"
  local cert_sha="$2"
  local uuid="$3"
  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi
  python3 - "$plist" "$cert_sha" "$LOCAL_TEAM_ID" "$LOCAL_BUNDLE_ID" "$uuid" <<'PY'
import base64
import datetime
import hashlib
import plistlib
import sys

try:
    plist_path, cert_sha, team, bundle, uuid = sys.argv[1:6]
    with open(plist_path, "rb") as handle:
        plist = plistlib.loads(handle.read())
    ents = plist.get("Entitlements") or {}
    expected_app = team + "." + bundle
    if ents.get("com.apple.application-identifier") != expected_app:
        sys.exit(1)
    if ents.get("com.apple.developer.team-identifier") != team:
        sys.exit(1)
    if ents.get("com.apple.security.get-task-allow") is not True:
        sys.exit(1)
    for key in (
        "com.apple.security.app-sandbox",
        "com.apple.security.files.user-selected.read-write",
        "com.apple.security.files.bookmarks.app-scope",
        "com.apple.security.network.client",
    ):
        if ents.get(key) is not True:
            sys.exit(1)
    if plist.get("ProvisionsAllDevices") is True:
        sys.exit(1)
    devices = plist.get("ProvisionedDevices") or []
    if not isinstance(devices, list) or not devices:
        sys.exit(1)
    uuid_l = uuid.strip().lower()
    if not uuid_l:
        sys.exit(1)
    if not any(isinstance(item, str) and item.strip().lower() == uuid_l for item in devices):
        sys.exit(1)
    teams = plist.get("TeamIdentifier") or []
    if team not in teams:
        sys.exit(1)
    prefixes = plist.get("ApplicationIdentifierPrefix") or []
    if team not in prefixes:
        sys.exit(1)
    platforms = plist.get("Platform") or []
    if platforms:
        names = []
        for item in platforms:
            if isinstance(item, str):
                names.append(item.lower())
        if not ({"osx", "macos", "mac"} & set(names)):
            sys.exit(1)
    exp = plist.get("ExpirationDate")
    if not isinstance(exp, datetime.datetime):
        sys.exit(1)
    now = datetime.datetime.now(datetime.timezone.utc)
    if exp.tzinfo is None:
        exp = exp.replace(tzinfo=datetime.timezone.utc)
    if exp < now:
        sys.exit(1)
    want = cert_sha.strip().upper()
    found = False
    for cert in plist.get("DeveloperCertificates") or []:
        if isinstance(cert, str):
            blob = base64.b64decode(cert)
        else:
            blob = bytes(cert)
        digests = (
            hashlib.sha1(blob).hexdigest().upper(),
            hashlib.sha256(blob).hexdigest().upper(),
        )
        if want in digests:
            found = True
            break
    if not found:
        sys.exit(1)
except Exception:
    sys.exit(1)
sys.exit(0)
PY
}

# Print the path of a development profile that matches this certificate and
# this Mac, or return 1. Distribution and Ad Hoc profiles do not match:
# they are not embedded next to an Apple Development signature.
find_matching_development_profile() {
  local cert_sha="$1"
  local uuid="$2"
  local dir f decoded
  for dir in \
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
    "$HOME/Library/MobileDevice/Provisioning Profiles"
  do
    [[ -d "$dir" ]] || continue
    for f in "$dir"/*.provisionprofile "$dir"/*.mobileprovision; do
      [[ -f "$f" ]] || continue
      decoded="$(mktemp /tmp/sts-profile.XXXXXX)"
      if ! security cms -D -i "$f" -o "$decoded" 2>/dev/null; then
        rm -f "$decoded"
        continue
      fi
      if profile_matches_development_cert "$decoded" "$cert_sha" "$uuid"; then
        rm -f "$decoded"
        printf '%s\n' "$f"
        return 0
      fi
      rm -f "$decoded"
    done
  done
  return 1
}

write_development_entitlements() {
  local out="$1"
  cat > "$out" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.application-identifier</key>
	<string>${LOCAL_APP_IDENTIFIER}</string>
	<key>com.apple.developer.team-identifier</key>
	<string>${LOCAL_TEAM_ID}</string>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-write</key>
	<true/>
	<key>com.apple.security.files.bookmarks.app-scope</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.get-task-allow</key>
	<true/>
</dict>
</plist>
EOF
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$out" >/dev/null
  fi
}

# Choose the identity once per process. A development profile is used only
# when it was issued for that Apple Development certificate, names
# com.derry.SmartTelescopeSort, and lists this Mac. Otherwise the safe
# sandbox entitlements are used and no profile is embedded.
prepare_local_signing() {
  local safe="$1"
  local identities record hash name uuid profile
  if [[ "$_LOCAL_SIGN_READY" == "1" && "$_LOCAL_SIGN_SAFE" == "$safe" ]]; then
    return 0
  fi
  if [[ ! -f "$safe" ]]; then
    echo "Missing entitlements: $safe" >&2
    return 1
  fi
  reject_profile_entitlements "$safe"
  identities="$(security find-identity -p codesigning -v 2>/dev/null || true)"
  uuid="$(local_mac_hardware_uuid || true)"
  profile=""
  hash=""
  name=""
  if [[ -n "$uuid" ]]; then
    while IFS=$'\t' read -r hash name; do
      [[ -n "$hash" && -n "$name" ]] || continue
      if ! valid_identity_hash "$hash"; then
        hash=""
        name=""
        continue
      fi
      profile="$(find_matching_development_profile "$hash" "$uuid" || true)"
      if [[ -n "$profile" ]]; then
        break
      fi
      hash=""
      name=""
      profile=""
    done <<EOF
$(printf '%s\n' "$identities" | list_identity_records "Apple Development:")
EOF
  else
    echo "Could not read this Mac's hardware UUID, so no provisioning profile will be embedded." >&2
  fi

  if [[ -n "$profile" && -n "$name" && -n "$hash" ]]; then
    LOCAL_SIGN_IDENTITY="$name"
    LOCAL_SIGN_HASH="$hash"
    LOCAL_SIGN_PROFILE="$profile"
    LOCAL_SIGN_ENTITLEMENTS="$(mktemp /tmp/sts-entitlements.XXXXXX)"
    write_development_entitlements "$LOCAL_SIGN_ENTITLEMENTS"
    echo "Local signing identity: $LOCAL_SIGN_IDENTITY"
    echo "Development profile for $LOCAL_APP_IDENTIFIER matches this certificate and this Mac."
    echo "Embedding that profile. Entitlements include application-identifier and team-identifier."
  else
    record="$(printf '%s\n' "$identities" | pick_local_signing_record)"
    case "$record" in
      *$'\t'*) ;;
      *) record="" ;;
    esac
    hash="${record%%$'\t'*}"
    name="${record#*$'\t'}"
    if [[ -z "$record" ]] || ! valid_identity_hash "$hash" || [[ -z "$name" ]]; then
      echo "No Apple Development, Mac Developer, or Developer ID Application identity in the login keychain." >&2
      echo "Refusing to sign the local test app ad-hoc or with Apple Distribution / 3rd Party Mac Developer." >&2
      echo "A missing Apple Distribution certificate does not install the App Store build. Install an Apple Development certificate (Xcode → Settings → Accounts) and run this script again." >&2
      return 1
    fi
    LOCAL_SIGN_IDENTITY="$name"
    LOCAL_SIGN_HASH="$hash"
    LOCAL_SIGN_PROFILE=""
    LOCAL_SIGN_ENTITLEMENTS="$safe"
    if [[ -n "$uuid" ]]; then
      echo "No development profile was embedded. A profile is used only when it is an Apple Development profile for $LOCAL_APP_IDENTIFIER, lists this Mac, and contains that certificate."
    fi
    echo "Local signing identity: $LOCAL_SIGN_IDENTITY"
    echo "Signing with sandbox, user-selected files, bookmarks, and network.client."
    echo "Not embedding a provisioning profile."
    echo "Omitting com.apple.application-identifier and com.apple.developer.team-identifier."
  fi
  _LOCAL_SIGN_READY=1
  _LOCAL_SIGN_SAFE="$safe"
}

safe_entitlement_keys_present() {
  local dumped="$1"
  local key
  for key in \
    "com.apple.security.app-sandbox" \
    "com.apple.security.files.user-selected.read-write" \
    "com.apple.security.files.bookmarks.app-scope" \
    "com.apple.security.network.client"
  do
    if ! grep -q "$key" <<<"$dumped"; then
      return 1
    fi
  done
}

embedded_profile_matches_leaf() {
  local app="$1"
  local tmp hash decoded status uuid
  uuid="$(local_mac_hardware_uuid || true)"
  [[ -n "$uuid" ]] || return 1
  [[ -f "$app/Contents/embedded.provisionprofile" ]] || return 1
  tmp="$(mktemp -d /tmp/sts-certs.XXXXXX)"
  hash=""
  if codesign -d --extract-certificates="$tmp/cert-" "$app" >/dev/null 2>&1 && [[ -f "$tmp/cert-0" ]]; then
    hash="$(openssl dgst -sha1 "$tmp/cert-0" 2>/dev/null | awk '{print $NF}' || true)"
    hash="${hash##*=}"
    hash="$(printf '%s' "$hash" | tr -d ':' | tr '[:lower:]' '[:upper:]')"
  fi
  rm -rf "$tmp"
  if ! valid_identity_hash "$hash"; then
    hash="${LOCAL_SIGN_HASH:-}"
  fi
  if ! valid_identity_hash "$hash"; then
    return 1
  fi
  decoded="$(mktemp /tmp/sts-profile.XXXXXX)"
  if ! security cms -D -i "$app/Contents/embedded.provisionprofile" -o "$decoded" 2>/dev/null; then
    rm -f "$decoded"
    return 1
  fi
  if profile_matches_development_cert "$decoded" "$hash" "$uuid"; then
    status=0
  else
    status=1
  fi
  rm -f "$decoded"
  return "$status"
}

# Quiet check. Returns 0 when the bundle is a developer-signed local app
# with the sandbox set, and the restricted entitlements appear only beside
# a matching development profile.
local_signature_is_developer() {
  local app="$1"
  local dumped sig
  [[ -d "$app" ]] || return 1
  codesign --verify --strict "$app" >/dev/null 2>&1 || return 1
  sig="$(codesign -dv "$app" 2>&1 || true)"
  if grep -q "Signature=adhoc" <<<"$sig" || grep -q "flags=0x2(adhoc)" <<<"$sig"; then
    return 1
  fi
  if grep -E -q "Authority=(Apple Distribution|3rd Party Mac Developer)" <<<"$sig"; then
    return 1
  fi
  if ! grep -E -q "Authority=(Apple Development|Mac Developer|Developer ID Application):" <<<"$sig"; then
    return 1
  fi
  dumped="$(codesign -d --entitlements :- "$app" 2>/dev/null || true)"
  safe_entitlement_keys_present "$dumped" || return 1
  if [[ -f "$app/Contents/embedded.provisionprofile" ]]; then
    embedded_profile_matches_leaf "$app" || return 1
    if ! grep -q "com.apple.application-identifier" <<<"$dumped"; then
      return 1
    fi
    if ! grep -q "com.apple.developer.team-identifier" <<<"$dumped"; then
      return 1
    fi
    if ! grep -q "${LOCAL_APP_IDENTIFIER}" <<<"$dumped"; then
      return 1
    fi
  else
    if grep -q "com.apple.application-identifier" <<<"$dumped"; then
      return 1
    fi
    if grep -q "com.apple.developer.team-identifier" <<<"$dumped"; then
      return 1
    fi
  fi
  return 0
}

assert_local_developer() {
  local app="$1"
  if local_signature_is_developer "$app"; then
    codesign --verify --strict --verbose=2 "$app"
    return 0
  fi
  echo "Local test app is not signed with Apple Development, Mac Developer, or Developer ID Application: $app" >&2
  echo "Apple Distribution and ad-hoc signatures are refused for the app you double-click." >&2
  codesign -dv --verbose=4 "$app" 2>&1 | head -n 40 >&2 || true
  codesign -d --entitlements :- "$app" 2>&1 | head -n 60 >&2 || true
  return 1
}

# Sign once, after Assets.car and every other resource are already in the bundle.
# No --deep: a normal bundle signature is what gets verified.
sign_local_developer() {
  local app="$1"
  local safe_entitlements="$2"

  if [[ ! -d "$app" ]]; then
    echo "Not an app bundle: $app" >&2
    return 1
  fi
  if [[ ! -x "$app/Contents/MacOS/SmartTelescopeSort" ]]; then
    echo "Missing executable: $app/Contents/MacOS/SmartTelescopeSort" >&2
    return 1
  fi
  prepare_local_signing "$safe_entitlements"
  rm -f "$app/Contents/embedded.provisionprofile"
  if [[ -n "$LOCAL_SIGN_PROFILE" ]]; then
    xattr -d com.apple.quarantine "$LOCAL_SIGN_PROFILE" 2>/dev/null || true
    cp "$LOCAL_SIGN_PROFILE" "$app/Contents/embedded.provisionprofile"
  fi
  xattr -cr "$app" 2>/dev/null || true
  chmod +x "$app/Contents/MacOS/SmartTelescopeSort"
  echo "Signing $(basename "$app")"
  echo "  identity: $LOCAL_SIGN_IDENTITY"
  if [[ -n "$LOCAL_SIGN_PROFILE" ]]; then
    echo "  profile: $LOCAL_SIGN_PROFILE"
  else
    echo "  profile: none"
  fi
  # Developer ID needs the hardened runtime. Apple Development and Mac
  # Developer stay a normal development signature (no --timestamp, no --deep).
  if [[ "$LOCAL_SIGN_IDENTITY" == "Developer ID Application:"* ]]; then
    codesign --force --options runtime --timestamp \
      --identifier "$LOCAL_BUNDLE_ID" \
      --entitlements "$LOCAL_SIGN_ENTITLEMENTS" \
      --sign "$LOCAL_SIGN_HASH" \
      "$app"
  else
    codesign --force \
      --identifier "$LOCAL_BUNDLE_ID" \
      --entitlements "$LOCAL_SIGN_ENTITLEMENTS" \
      --sign "$LOCAL_SIGN_HASH" \
      "$app"
  fi
  assert_local_developer "$app"
}

# Confirm an ad-hoc signature. Used for the screenshot helper only.
# The app installed in /Applications uses sign_local_developer.
assert_local_adhoc() {
  local app="$1"
  local dumped sig
  codesign --verify --strict --verbose=2 "$app"
  dumped="$(codesign -d --entitlements :- "$app" 2>/dev/null || true)"
  if grep -q "com.apple.application-identifier" <<<"$dumped"; then
    echo "Ad-hoc app still has com.apple.application-identifier: $app" >&2
    return 1
  fi
  if grep -q "com.apple.developer.team-identifier" <<<"$dumped"; then
    echo "Ad-hoc app still has com.apple.developer.team-identifier: $app" >&2
    return 1
  fi
  sig="$(codesign -dv "$app" 2>&1 || true)"
  if grep -E -q "Authority=(Apple Distribution|3rd Party Mac Developer|Apple Development|Developer ID Application|Mac Developer)" <<<"$sig"; then
    echo "Ad-hoc helper must not use an Apple signing identity: $app" >&2
    printf '%s\n' "$sig" >&2
    return 1
  fi
  if ! grep -q "Signature=adhoc" <<<"$sig" && ! grep -q "flags=0x2(adhoc)" <<<"$sig"; then
    echo "Helper app is not ad-hoc signed: $app" >&2
    printf '%s\n' "$sig" >&2
    return 1
  fi
  if grep -q "^TeamIdentifier=" <<<"$sig" && ! grep -q "^TeamIdentifier=not set" <<<"$sig"; then
    echo "Ad-hoc helper has a team identifier: $app" >&2
    printf '%s\n' "$sig" >&2
    return 1
  fi
}

# Not used for the installed test app. The screenshot bundle has a different
# bundle id and is not double-clicked from /Applications.
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

# Copy src onto dest. The privileged step only copies; codesign runs as the
# user who owns the login keychain. The installed bundle is signed again
# only when the copied signature does not verify.
install_one_local_app() {
  local src="$1"
  local dest="$2"
  local entitlements="$3"
  local parent script owner group
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
  if ! local_signature_is_developer "$src"; then
    sign_local_developer "$src" "$entitlements"
  fi
  echo "Installing local test app -> $dest"
  owner="$(id -un)"
  group="$(id -gn)"
  script="$(mktemp /tmp/sts-install.XXXXXX)"
  cat > "$script" <<EOF
#!/bin/bash
set -euo pipefail
rm -rf $(printf '%q' "$dest")
ditto $(printf '%q' "$src") $(printf '%q' "$dest")
xattr -cr $(printf '%q' "$dest") || true
chmod +x $(printf '%q' "$dest/Contents/MacOS/SmartTelescopeSort")
if [[ "\$(id -u)" -eq 0 ]]; then
  chown -R $(printf '%q' "$owner:$group") $(printf '%q' "$dest")
fi
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
  if ! local_signature_is_developer "$dest"; then
    echo "Copied signature did not verify. Signing the installed copy once, without --deep."
    sign_local_developer "$dest" "$entitlements"
  fi
  assert_local_developer "$dest"
  register_app "$dest"
}

# Always replace the bundle Rick is double-clicking, plus Telescope Data Sort.app.
install_local_test_app() {
  local src="$1"
  local entitlements="$2"
  local root_dir="${3:-}"
  local host installed bin

  reject_profile_entitlements "$entitlements"
  prepare_local_signing "$entitlements"
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
