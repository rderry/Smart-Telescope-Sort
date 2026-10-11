#!/bin/bash
# Golden comparison on this Mac: the Mac sorter (Swift, compiled from App/Sources into /tmp) and the Windows port's
# Core (via sts-check) scan, plan and copy-sort the same copy of Demo Captures. Their reports, the sorted Targets
# trees and the untouched originals must match. Everything is written under /tmp/sts-golden.
set -euo pipefail
WIN="$(cd "$(dirname "$0")/../.." && pwd)"
MAC="$(cd "$WIN/.." && pwd)"
OUT="${STS_GOLDEN_OUT:-/tmp/sts-golden}"
DOTNET="${STS_DOTNET:-/Volumes/Large Drive/Scratch/dotnet8-sdk/dotnet}"
case "$OUT" in /tmp/*|/private/tmp/*) ;; *) echo "OUT must be under /tmp" >&2; exit 2 ;; esac

rm -rf "$OUT"
mkdir -p "$OUT/bin"
for side in mac win; do
  mkdir -p "$OUT/$side"
  cp -Rp "$MAC/Demo Captures" "$OUT/$side/Captures"
done

SDK="$(xcrun --sdk macosx --show-sdk-path)"
nice -n 10 xcrun swiftc -sdk "$SDK" -target "$(uname -m)-apple-macos15.0" -parse-as-library -Onone \
  "$MAC/App/Sources/TelescopeKind.swift" "$MAC/App/Sources/CaptureSorter.swift" "$WIN/tools/mac-golden/GoldenReport.swift" \
  -o "$OUT/bin/GoldenReport"
"$WIN/scripts/mac/dotnet.sh" build "$WIN/src/SmartTelescopeSort.Cli" -nologo -v q -o "$OUT/bin/cli" >/dev/null

mac() { nice -n 10 "$OUT/bin/GoldenReport" "$OUT/mac/Captures" "$OUT/mac/Library" "$@"; }
win() { nice -n 10 "$DOTNET" "$OUT/bin/cli/sts-check.dll" report "$OUT/win/Captures" "$OUT/win/Library" "$@"; }
manifest() { nice -n 10 "$DOTNET" "$OUT/bin/cli/sts-check.dll" manifest "$1"; }

failed=0
compare() {
  local name="$1"
  if diff -u "$OUT/$name.mac.txt" "$OUT/$name.win.txt" > "$OUT/$name.diff"; then
    echo "MATCH  $name ($(wc -l < "$OUT/$name.mac.txt" | tr -d ' ') lines)"
  else
    echo "DIFFER $name — see $OUT/$name.diff"
    failed=1
  fi
}

manifest "$OUT/mac/Captures" > "$OUT/originals-before.txt"
for side in mac win; do
  "$side" tiff,fits > "$OUT/1-plan.$side.txt"
  "$side" tiff,fits,jpeg > "$OUT/2-plan-all-types.$side.txt"
  "$side" tiff,fits --sort > "$OUT/3-sort.$side.txt"
  "$side" tiff,fits --sort > "$OUT/4-sort-again.$side.txt"
  manifest "$OUT/$side/Library" > "$OUT/5-targets-tree.$side.txt"
  manifest "$OUT/$side/Captures" > "$OUT/6-originals-after.$side.txt"
done
for name in 1-plan 2-plan-all-types 3-sort 4-sort-again 5-targets-tree 6-originals-after; do compare "$name"; done
if diff -q "$OUT/originals-before.txt" "$OUT/6-originals-after.win.txt" >/dev/null; then
  echo "MATCH  originals untouched by the Windows port ($(wc -l < "$OUT/originals-before.txt" | tr -d ' ') files, same bytes and dates)"
else
  echo "DIFFER originals changed"; failed=1
fi
exit $failed
