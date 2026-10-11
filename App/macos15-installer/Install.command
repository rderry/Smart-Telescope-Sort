#!/bin/bash
# Processor-sensitive installer for Telescope Data Sort (macOS 15).
# Installs only the matching CPU build, then asks where to place the user manual PDF.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PAYLOADS="$HERE/Payloads"
APP_NAME="Telescope Data Sort.app"
OLD_APP_NAME="Smart Telescope Sort.app"
MANUAL_PDF="$HERE/Telescope-Data-Sort-User-Manual.pdf"
DEST="/Applications"

detect_cpu() {
  local hw_arm translated uname_m

  hw_arm="$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)"
  if [[ "$hw_arm" == "1" ]]; then
    echo "arm64"
    return
  fi

  translated="$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)"
  if [[ "$translated" == "1" ]]; then
    echo "arm64"
    return
  fi

  uname_m="$(uname -m)"
  case "$uname_m" in
    arm64) echo "arm64" ;;
    x86_64|i386|i686) echo "x86_64" ;;
    *) echo "unknown:$uname_m" ;;
  esac
}

arch="$(detect_cpu)"
case "$arch" in
  arm64) cpu_label="Apple Silicon (arm64)" ;;
  x86_64) cpu_label="Intel (x86_64)" ;;
  *)
    osascript -e "display alert \"Unsupported processor\" message \"Could not choose a build for this Mac.\nDetected: $arch\nNeed Apple Silicon or Intel.\"" 2>/dev/null || true
    echo "Unsupported architecture: $arch" >&2
    exit 1
    ;;
esac

echo "Detected CPU: $cpu_label"

SRC="$PAYLOADS/$arch/$APP_NAME"
if [[ ! -d "$SRC" ]]; then
  osascript -e "display alert \"Missing payload\" message \"No $cpu_label build found at:\n$SRC\"" 2>/dev/null || true
  echo "Missing payload: $SRC" >&2
  exit 1
fi

choice="$(osascript <<EOF 2>/dev/null || true
set question to display dialog "This Mac is $cpu_label.

Only the matching processor build will be installed (the other CPU build in this package is ignored).

Install Telescope Data Sort into /Applications?
Any existing copy with the same name will be replaced, and a copy under the app's earlier name (Smart Telescope Sort) is moved to the Trash. Your settings are kept.

After the app is installed you will choose where to save the User Manual PDF." buttons {"Cancel", "Install"} default button "Install" with title "Telescope Data Sort installer"
if button returned of question is "Install" then
  return "install"
else
  return "cancel"
end if
EOF
)" || true

if [[ "${choice:-}" == "cancel" ]]; then
  echo "Cancelled."
  exit 0
fi

if [[ ! -d "$DEST" ]]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

TARGET="$DEST/$APP_NAME"
echo "Installing $cpu_label build -> $TARGET"
rm -rf "$TARGET"
ditto "$SRC" "$TARGET"

xattr -cr "$TARGET" 2>/dev/null || true
codesign --force --deep --sign - "$TARGET" >/dev/null 2>&1 || true

installed_arch="$(lipo -archs "$TARGET/Contents/MacOS/SmartTelescopeSort" 2>/dev/null || true)"
if [[ "$installed_arch" != *"$arch"* ]]; then
  osascript -e "display alert \"Install mismatch\" message \"Expected $arch but installed binary is: $installed_arch\"" 2>/dev/null || true
  echo "Install mismatch: expected $arch, got $installed_arch" >&2
  exit 1
fi

OLD_APP="$DEST/$OLD_APP_NAME"
if [[ -d "$OLD_APP" ]]; then
  if osascript -e "tell application \"Finder\" to delete (POSIX file \"$OLD_APP\" as alias)" >/dev/null 2>&1; then
    echo "Moved the earlier $OLD_APP_NAME to the Trash."
  else
    echo "Could not move $OLD_APP to the Trash; remove it yourself if you no longer need it." >&2
  fi
fi

pdf_note="skipped"
if [[ -f "$MANUAL_PDF" ]]; then
  pdf_dest="$(osascript <<'EOF' 2>/dev/null || true
try
  set theFolder to choose folder with prompt "Where should the Telescope Data Sort User Manual PDF be saved?" default location (path to documents folder)
  return POSIX path of theFolder
on error
  return ""
end try
EOF
)" || true
  pdf_dest="${pdf_dest%$'\r'}"
  pdf_dest="${pdf_dest%/}"
  if [[ -n "${pdf_dest:-}" && -d "$pdf_dest" ]]; then
    cp "$MANUAL_PDF" "$pdf_dest/Telescope-Data-Sort-User-Manual.pdf"
    xattr -cr "$pdf_dest/Telescope-Data-Sort-User-Manual.pdf" 2>/dev/null || true
    pdf_note="$pdf_dest/Telescope-Data-Sort-User-Manual.pdf"
    echo "Manual PDF saved -> $pdf_note"
  else
    echo "PDF placement skipped by user."
    pdf_note="not saved (cancelled)"
  fi
else
  echo "Manual PDF not found next to Install.command."
  pdf_note="missing from installer package"
fi

osascript <<EOF 2>/dev/null || true
display dialog "Installed one build only:

CPU: $cpu_label
Arch: $installed_arch
App: $TARGET

User Manual PDF:
$pdf_note

(The PDF is also inside the app — Help → Telescope Data Sort User Manual.)" buttons {"OK"} default button "OK" with title "Install complete"
EOF

echo "Done: $TARGET ($installed_arch)"
open -R "$TARGET" 2>/dev/null || true
if [[ -f "${pdf_note:-}" ]]; then
  open -R "$pdf_note" 2>/dev/null || true
fi
