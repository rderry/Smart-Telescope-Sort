#!/bin/bash
# Runs the local .NET 8 SDK by full path, niced, after any other heavy build on this Mac has finished.
# Usage: scripts/mac/dotnet.sh test tests/SmartTelescopeSort.Core.Tests   (any dotnet arguments)
set -euo pipefail
DOTNET="${STS_DOTNET:-/Volumes/Large Drive/Scratch/dotnet8-sdk/dotnet}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

busy() {
  ps -axo pid=,comm= | awk -v me="$$" '$1 != me' | grep -Eiq '(^|/)(xcodebuild|swift-build|swift-frontend|dotnet|MSBuild)$'
}
waited=0
while busy; do
  if (( waited == 0 )); then echo "Another heavy build is running; waiting…" >&2; fi
  sleep 20
  waited=$((waited + 20))
  if (( waited >= 3600 )); then echo "Gave up waiting after an hour." >&2; exit 75; fi
done

export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
exec nice -n 10 "$DOTNET" "$@"
