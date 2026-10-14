#!/usr/bin/env bash
set -euo pipefail
S="$(cd "$(dirname "$0")/../.." && pwd)/scripts/check-private-registry.sh"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
n=0
reg() { n=$((n + 1)); printf '%s\nXLESS_REGISTRY_PRIVATE=true\n' "$1" > "$t/$n"; echo "$t/$n"; }
refuse() { "$S" "$(reg "XLESS_REGISTRY=$1")" >/dev/null 2>&1 && fail "accepted '$1'"; true; }
accept() { local out; out=$("$S" "$(reg "XLESS_REGISTRY=$1")") || fail "rejected '$1'"; [[ "$out" == "$2" ]] || fail "'$1' printed '$out', want '$2'"; }

"$S" "$t/none" 2>/dev/null && fail "missing file accepted"
printf 'XLESS_REGISTRY=ghcr.io/me\nXLESS_REGISTRY_PRIVATE=false\n' > "$t/a"; "$S" "$t/a" 2>/dev/null && fail "non-private accepted"

# Docker Hub, explicit or implicit (a bare name means docker.io/<name>, public by default), any case.
for r in docker.io/me DOCKER.IO/me Docker.Io/me docker.io index.docker.io/me index.docker.io registry-1.docker.io/me registry-1.docker.io \
         myuser myuser/sub MyUser; do refuse "$r"; done
# Empty or unset, even when the caller's environment has a value.
refuse ""
printf 'XLESS_REGISTRY_PRIVATE=true\n' > "$t/unset"; XLESS_REGISTRY=ghcr.io/env "$S" "$t/unset" >/dev/null 2>&1 && fail "unset accepted (env leaked)"

accept ghcr.io/me ghcr.io/me
accept GHCR.io/Me ghcr.io/me
accept localhost:5000/x localhost:5000/x
accept localhost/x localhost/x
accept registry.example.com:5000/team registry.example.com:5000/team
accept localhost:5000 localhost:5000
accept registry.example.com registry.example.com
echo PASS
