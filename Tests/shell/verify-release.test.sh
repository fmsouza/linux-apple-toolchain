#!/usr/bin/env bash
# scripts/release-assets.sh and scripts/verify-release.sh: the release workflow's check that the stamped tarballs install
# and report their version before anything is published. Tarballs are built with scripts/package-release.sh from stubs.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
export XLESS_CHECKOUTS="$t/checkouts" XLESS_STRIP=true XLESS_UNAME_S=Linux XLESS_UNAME_M=x86_64
mkdir -p "$t/checkouts"
for id in $(sed -n 's/.*"identity" : "\(.*\)",/\1/p' "$repo/Package.resolved"); do
  mkdir -p "$t/checkouts/$id"; echo "licence of $id" > "$t/checkouts/$id/LICENSE"
done

# dist <dir> <version> <what the stub prints>: both tarballs of <version>, their binaries printing <what>.
dist() {
  local a
  mkdir -p "$1"
  for a in x86_64 arm64; do
    printf '#!/bin/sh\necho "%s"\n' "$3" > "$t/xless"; chmod +x "$t/xless"
    bash "$repo/scripts/package-release.sh" "$2" "$a" "$t/xless" "$1" >/dev/null
  done
  rm -f "$1/SHA256SUMS"   # package-release.sh's per-leg file; release-assets.sh writes the release's
}

# A good release: assets made, installed pinned and as the latest, both report the version.
dist "$t/good" 1.4.0 1.4.0
bash "$repo/scripts/release-assets.sh" 1.4.0 "$t/good" >/dev/null || fail "release-assets refused a good dist"
[[ "$(wc -l < "$t/good/SHA256SUMS" | tr -d ' ')" == 2 ]] || fail "SHA256SUMS: $(cat "$t/good/SHA256SUMS")"
head -n1 "$t/good/SHA256SUMS" | grep -q ' xless-1.4.0-linux-arm64.tar.gz$' || fail "SHA256SUMS not sorted by name"
cmp -s "$repo/scripts/install.sh" "$t/good/install.sh" || fail "install.sh not copied"
out=$(bash "$repo/scripts/verify-release.sh" 1.4.0 "$t/good" 2>&1) || fail "verify refused a good release: $out"
grep -q 'v1.4.0: xless 1.4.0 installed' <<<"$out" || fail "pinned install not checked: $out"
grep -q 'latest: xless 1.4.0 installed' <<<"$out" || fail "latest install not checked: $out"

# A binary that reports another version (a stamp that didn't take) fails.
dist "$t/unstamped" 1.4.0 0.0.0-dev
bash "$repo/scripts/release-assets.sh" 1.4.0 "$t/unstamped" >/dev/null
out=$(bash "$repo/scripts/verify-release.sh" 1.4.0 "$t/unstamped" 2>&1) && fail "verify passed a 0.0.0-dev binary"
grep -q "printed '0.0.0-dev', expected '1.4.0'" <<<"$out" || fail "wrong message: $out"

# A wrong share/xless/VERSION fails.
dist "$t/badshare" 1.4.0 1.4.0
for a in x86_64 arm64; do
  n="xless-1.4.0-linux-$a"; mkdir -p "$t/x"; tar -xzf "$t/badshare/$n.tar.gz" -C "$t/x"
  echo 0.0.0-dev > "$t/x/$n/share/xless/VERSION"; tar -czf "$t/badshare/$n.tar.gz" -C "$t/x" "$n"; rm -rf "$t/x"
done
bash "$repo/scripts/release-assets.sh" 1.4.0 "$t/badshare" >/dev/null
out=$(bash "$repo/scripts/verify-release.sh" 1.4.0 "$t/badshare" 2>&1) && fail "verify passed a wrong share/xless/VERSION"
grep -q "share/xless/VERSION is '0.0.0-dev'" <<<"$out" || fail "wrong message: $out"

# Tarballs named for another version (or one missing) are refused before any checksum is written.
dist "$t/misnamed" 1.3.9 1.4.0
out=$(bash "$repo/scripts/release-assets.sh" 1.4.0 "$t/misnamed" 2>&1) && fail "release-assets took 1.3.9 tarballs for 1.4.0"
grep -q 'expected \[xless-1.4.0-linux-arm64.tar.gz xless-1.4.0-linux-x86_64.tar.gz\]' <<<"$out" || fail "wrong message: $out"
[[ ! -e "$t/misnamed/SHA256SUMS" ]] || fail "SHA256SUMS written for a refused dist"
rm "$t/good/xless-1.4.0-linux-x86_64.tar.gz"
bash "$repo/scripts/release-assets.sh" 1.4.0 "$t/good" >/dev/null 2>&1 && fail "release-assets took a dist without x86_64"
echo "verify-release.test.sh: ok"
