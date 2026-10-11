#!/bin/bash
# Builds the Windows icon and the Store tile images with the Mac app's icon generator (Pillow + numpy):
#   src/SmartTelescopeSort.App/Assets/AppIcon.ico          16–256 px, PNG frames
#   installer/Store/Assets/*.png                            MSIX logos and splash
set -euo pipefail
WIN="$(cd "$(dirname "$0")/../.." && pwd)"
python3 "$WIN/../App/Icons/make-icons.py" --windows
ls -la "$WIN/src/SmartTelescopeSort.App/Assets/AppIcon.ico" "$WIN/installer/Store/Assets"
