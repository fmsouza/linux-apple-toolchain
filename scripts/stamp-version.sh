#!/usr/bin/env bash
# Stamps a release version into the working tree: Sources/XlessCore/Version.swift (`current`) and versions.env
# (XLESS_VERSION). Used only by CI before a release build; the source tree stays at 0.0.0-dev.
#   scripts/stamp-version.sh <x.y.z>
set -euo pipefail
v="${1:-}"
if [[ ! "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: scripts/stamp-version.sh <x.y.z>   (got '$v')" >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
version_swift="$root/Sources/XlessCore/Version.swift"
versions_env="$root/versions.env"
grep -q 'static let current = "' "$version_swift" || { echo "stamp-version: no 'current' in $version_swift" >&2; exit 1; }
grep -q '^XLESS_VERSION=' "$versions_env" || { echo "stamp-version: no XLESS_VERSION in $versions_env" >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
sed "s/static let current = \".*\"/static let current = \"$v\"/" "$version_swift" > "$tmp/Version.swift"
sed "s/^XLESS_VERSION=.*/XLESS_VERSION=$v/" "$versions_env" > "$tmp/versions.env"
cat "$tmp/Version.swift" > "$version_swift"
cat "$tmp/versions.env" > "$versions_env"
echo "stamped $v"
