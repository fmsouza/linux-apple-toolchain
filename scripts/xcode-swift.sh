#!/usr/bin/env bash
# Ruling R10: the Swift toolchain an Xcode's image chain compiles app code with. Measures the Xcode's Swift black-box
# (its default toolchain's `swift --version`), looks the Xcode build up in versions.env's map (XCODE_SWIFT_<build>),
# checks the entry against the map's rule (same major.minor as Apple's Swift, patch not above it), and prints the
# make variables for docker/Dockerfile.sdk, one per line:
#   APP_SWIFT_VERSION=<x.y.z>            (empty when it is versions.env's SWIFT_VERSION: the image's own Swift)
#   APP_SWIFT_URL_AARCH64=… APP_SWIFT_SHA256_AARCH64=… APP_SWIFT_URL_X86_64=… APP_SWIFT_SHA256_X86_64=…
# Refuses (exit 2) an Xcode without an entry, an entry that breaks the rule, and a release without pinned downloads.
# Usage: scripts/xcode-swift.sh <Xcode.app> <Xcode build>       (scripts/build-images.sh runs it)
#   VERSIONS_ENV: the versions file (default: the repository's versions.env).
set -euo pipefail

die() { echo "xcode-swift: $*" >&2; exit 2; }
[[ $# -eq 2 ]] || die "usage: $0 <Xcode.app> <Xcode build>"
xcode="$1"; build="$2"
versions="${VERSIONS_ENV:-$(cd "$(dirname "$0")/.." && pwd)/versions.env}"
[[ "$build" =~ ^[0-9A-Za-z]+$ ]] || die "unexpected Xcode build '$build'"
set -a; . "$versions"; set +a

swift="$xcode/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
[[ -x "$swift" ]] || die "$swift is missing: pass a full Xcode.app"
line="$("$swift" --version 2>/dev/null | grep -m1 'Swift version' || true)"
apple="$(sed -nE 's/.*Swift version ([0-9]+(\.[0-9]+){0,2}).*/\1/p' <<<"$line")"
[[ -n "$apple" ]] || die "no Swift version in \`$swift --version\`"

var="XCODE_SWIFT_$build"
mapped="${!var:-}"
[[ -n "$mapped" ]] || die "Xcode build $build ships $line, and versions.env has no $var: add $var=<the open-source release with the same major.minor and the highest patch not above ${apple}> (and its SWIFT_TOOLCHAIN_<x_y_z>_* downloads unless it is SWIFT_VERSION $SWIFT_VERSION)"
[[ "$mapped" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$var=$mapped is not a release (x.y.z)"
IFS=. read -r am an ap _ <<<"$apple.0.0"
IFS=. read -r om on op <<<"$mapped"
[[ "$am" == "$om" && "$an" == "$on" && "$op" -le "$ap" ]] \
  || die "$var=$mapped breaks the map's rule for Xcode build $build's Swift $apple (same major.minor, patch not above Apple's)"
echo "==> Xcode build $build: $line → swift-$mapped-RELEASE" >&2

if [[ "$mapped" == "$SWIFT_VERSION" ]]; then
  echo "APP_SWIFT_VERSION="
  exit 0
fi
key="SWIFT_TOOLCHAIN_${mapped//./_}"
echo "APP_SWIFT_VERSION=$mapped"
for a in AARCH64 X86_64; do
  for f in URL SHA256; do
    v="${key}_${f}_$a"
    [[ -n "${!v:-}" ]] || die "versions.env has no $v for swift-$mapped-RELEASE"
    echo "APP_SWIFT_${f}_$a=${!v}"
  done
done
