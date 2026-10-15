#!/usr/bin/env bash
# Regenerates Sources/XlessIB/Lowering/Rules/KnownFonts.swift on the Mac (Xcode 27.0 27A266a, iOS 27.0 runtime).
# Usage: scripts/ib-corpus/known-fonts.sh [simulator UDID]   (default: the first booted iOS 27.0 simulator)
# Inputs (names only, public CoreText APIs):
#   1. the font files under /System/Library/Fonts and under the iOS runtime's System/Library/Fonts;
#   2. CTFontManagerCopyAvailablePostScriptNames() for fonts under /System, on the Mac and inside the simulator
#      (available-font-names.swift), which adds aliases without a name-table entry (PingFang*).
set -euo pipefail
die() { echo "known-fonts: $*" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/scripts/ib-corpus"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

udid="${1:-$(xcrun simctl list devices booted | sed -n '/^-- iOS 27\.0 --/,/^--/s/.*(\([0-9A-F-]\{36\}\)) (Booted).*/\1/p' | head -1)}"
[[ -n $udid ]] || die "no booted iOS 27.0 simulator (boot one, or pass its UDID)"
mnt="$(mount | grep -o '/private/var/run/com.apple.security.cryptexd/mnt/com.apple.iPhoneOS.SimulatorRuntime[^ ]*' | head -1)"
[[ -n $mnt ]] || die "iOS simulator runtime not mounted"
runtime_fonts="$mnt/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.0.simruntime/Contents/Resources/RuntimeRoot/System/Library/Fonts"
[[ -d $runtime_fonts ]] || die "no iOS 27.0 runtime fonts at $runtime_fonts"

swift "$HERE/available-font-names.swift" > "$T/mac.txt"
xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator "$HERE/available-font-names.swift" -o "$T/available-font-names"
xcrun simctl spawn "$udid" "$T/available-font-names" > "$T/runtime.txt"
[[ -s $T/mac.txt && -s $T/runtime.txt ]] || die "no available font names"
swift "$HERE/known-fonts.swift" "$ROOT/Sources/XlessIB/Lowering/Rules/KnownFonts.swift" \
  --available "$T/mac.txt" --available "$T/runtime.txt" /System/Library/Fonts "$runtime_fonts"
