#!/usr/bin/env bash
# scripts/install.sh, run under dash (the shell `curl … | sh` is on Debian/Ubuntu; plain sh when dash is missing) against a
# file:// release built with scripts/package-release.sh from a stub binary.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
sh_bin=$(command -v dash || command -v sh)
echo "install.sh runs under $sh_bin"
export XLESS_CHECKOUTS="$t/checkouts" XLESS_STRIP=true
mkdir -p "$t/checkouts"
for id in $(sed -n 's/.*"identity" : "\(.*\)",/\1/p' "$repo/Package.resolved"); do
  mkdir -p "$t/checkouts/$id"; echo "licence of $id" > "$t/checkouts/$id/LICENSE"
done

# release <version>: a release directory with both arches at <rel>/download/v<version>/ (and /latest/download/ when asked).
rel="$t/rel"
release() {  # version [latest]
  local v=$1 d="$rel/download/v$1" a
  mkdir -p "$d"
  for a in x86_64 arm64; do
    printf '#!/bin/sh\necho "xless %s %s"\n' "$v" "$a" > "$t/stub-$a"; chmod +x "$t/stub-$a"
    bash "$repo/scripts/package-release.sh" "$v" "$a" "$t/stub-$a" "$d" >/dev/null
  done
  if [[ "${2:-}" == latest ]]; then rm -rf "$rel/latest"; mkdir -p "$rel/latest"; cp -R "$d" "$rel/latest/download"; fi
}
# A PATH with the tools the installer needs, a docker that works, and nothing else.
mkdir -p "$t/tools" "$t/tools-nodocker"
for c in curl tar gzip mktemp mv cp rm mkdir chmod cat awk sed grep uname dirname basename sha256sum shasum od tr head ls find sort wc cut date ln; do
  p=$(command -v "$c" 2>/dev/null || true)
  if [[ -n "$p" && "$p" == /* ]]; then ln -sf "$p" "$t/tools/$c"; ln -sf "$p" "$t/tools-nodocker/$c"; fi
done
printf '#!/bin/sh\nexit 0\n' > "$t/tools/docker"; chmod +x "$t/tools/docker"

run() {  # env... -- runs install.sh with the given extra env; sets $out and $rc
  rc=0; out=$(env "$@" "$sh_bin" "$repo/scripts/install.sh" 2>&1) || rc=$?
}
base=(XLESS_RELEASE_BASE="file://$rel" XLESS_UNAME_S=Linux XLESS_UNAME_M=x86_64 HOME="$t/home")
mkdir -p "$t/home"

release 1.2.3 latest

# Fresh install, latest, into a temp prefix on PATH.
p="$t/p1"
run "${base[@]}" XLESS_PREFIX="$p" PATH="$p/bin:$t/tools"
[[ $rc == 0 ]] || fail "fresh install exited $rc: $out"
[[ -x "$p/bin/xless" ]] || fail "no bin/xless"
[[ "$(cat "$p/share/xless/VERSION")" == 1.2.3 ]] || fail "VERSION"
[[ "$("$p/bin/xless")" == "xless 1.2.3 x86_64" ]] || fail "wrong binary installed"
echo "$out" | grep -qF "xless 1.2.3 installed to $p/bin/xless" || fail "no installed line: $out"
echo "$out" | grep -qF "next: xless setup --xcode ~/Downloads/Xcode_27.0.xip" || fail "no next line: $out"
echo "$out" | grep -q "export PATH=" && fail "PATH hint printed though prefix is on PATH"
echo "$out" | grep -qi "docker" && fail "docker warning though docker works: $out"
[[ -z "$(ls -A "$p/share" | grep -v '^xless$')" ]] || fail "temp files left in share: $(ls -A "$p/share")"

# --prefix works, and a newer pinned version replaces both.
release 1.3.0
rc=0; out=$(env "${base[@]}" XLESS_VERSION=v1.3.0 PATH="$p/bin:$t/tools" "$sh_bin" "$repo/scripts/install.sh" --prefix "$p" 2>&1) || rc=$?
[[ $rc == 0 ]] || fail "upgrade exited $rc: $out"
[[ "$(cat "$p/share/xless/VERSION")" == 1.3.0 ]] || fail "share not replaced"
[[ "$("$p/bin/xless")" == "xless 1.3.0 x86_64" ]] || fail "binary not replaced"

# A pinned version uses /download/v<version>/ and nothing else.
rm -rf "$rel/latest"
run "${base[@]}" XLESS_PREFIX="$t/p2" XLESS_VERSION=v1.2.3 PATH="$t/p2/bin:$t/tools"
[[ $rc == 0 ]] || fail "pinned install without /latest exited $rc: $out"
[[ "$(cat "$t/p2/share/xless/VERSION")" == 1.2.3 ]] || fail "pinned VERSION"
run "${base[@]}" XLESS_PREFIX="$t/p2b" XLESS_VERSION=9.9.9 PATH="$t/p2b/bin:$t/tools"
[[ $rc == 1 ]] || fail "an unreleased version should exit 1, got $rc"
release 1.2.3 latest

# A tampered tarball: exit 1, nothing replaced.
p="$t/p3"
run "${base[@]}" XLESS_PREFIX="$p" XLESS_VERSION=1.2.3 PATH="$p/bin:$t/tools" >/dev/null
printf 'x' >> "$rel/download/v1.3.0/xless-1.3.0-linux-x86_64.tar.gz"
run "${base[@]}" XLESS_PREFIX="$p" XLESS_VERSION=1.3.0 PATH="$p/bin:$t/tools"
[[ $rc == 1 ]] || fail "tampered tarball exited $rc, want 1: $out"
echo "$out" | grep -qi "sha256\|checksum\|verif" || fail "no checksum message: $out"
[[ "$(cat "$p/share/xless/VERSION")" == 1.2.3 ]] || fail "share replaced by a tampered tarball"
[[ "$("$p/bin/xless")" == "xless 1.2.3 x86_64" ]] || fail "binary replaced by a tampered tarball"
release 1.3.0

# Architectures.
run "${base[@]}" XLESS_UNAME_M=aarch64 XLESS_PREFIX="$t/pa" PATH="$t/pa/bin:$t/tools"
[[ $rc == 0 && "$("$t/pa/bin/xless")" == "xless 1.2.3 arm64" ]] || fail "aarch64 should install arm64: $out"
run "${base[@]}" XLESS_UNAME_M=x86_64 XLESS_PREFIX="$t/px" PATH="$t/px/bin:$t/tools"
[[ $rc == 0 && "$("$t/px/bin/xless")" == "xless 1.2.3 x86_64" ]] || fail "x86_64 should install x86_64: $out"
run "${base[@]}" XLESS_UNAME_M=riscv64 XLESS_PREFIX="$t/pr" PATH="$t/pr/bin:$t/tools"
[[ $rc == 1 ]] || fail "riscv64 exited $rc"
echo "$out" | grep -qi "unsupported" || fail "riscv64: no 'unsupported': $out"
[[ ! -e "$t/pr/bin/xless" ]] || fail "riscv64 installed something"

# A prefix that is not on PATH gets the export line.
run "${base[@]}" XLESS_PREFIX="$t/pn" PATH="$t/tools"
[[ $rc == 0 ]] || fail "off-PATH install exited $rc"
echo "$out" | grep -qF "export PATH=\"$t/pn/bin:\$PATH\"" || fail "no export PATH line: $out"

# No docker: still exit 0, with the link.
run "${base[@]}" XLESS_PREFIX="$t/pd" PATH="$t/pd/bin:$t/tools-nodocker"
[[ $rc == 0 ]] || fail "no-docker install exited $rc: $out"
echo "$out" | grep -qF "https://docs.docker.com/engine/install/" || fail "no docker link: $out"
# docker present but the daemon is unreachable.
mkdir -p "$t/tools-down"; cp -P "$t/tools-nodocker"/* "$t/tools-down/"
printf '#!/bin/sh\nexit 1\n' > "$t/tools-down/docker"; chmod +x "$t/tools-down/docker"
run "${base[@]}" XLESS_PREFIX="$t/pe" PATH="$t/pe/bin:$t/tools-down"
[[ $rc == 0 ]] || fail "daemon-down install exited $rc"
echo "$out" | grep -qF "https://docs.docker.com/engine/install/" || fail "daemon down: no docker link: $out"

echo "install.test.sh: OK"
