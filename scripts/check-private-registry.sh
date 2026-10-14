#!/usr/bin/env bash
# Prints the registry to push SDK images to, or exits non-zero. Never pushes anything itself.
set -euo pipefail
f="${1:-registry.env}"
[[ -f "$f" ]] || { echo "error: $f missing — copy registry.env.example and fill it in" >&2; exit 1; }
unset XLESS_REGISTRY XLESS_REGISTRY_PRIVATE   # only the file counts, never the caller's environment
# shellcheck disable=SC1090
source "$f"
r="$(printf '%s' "${XLESS_REGISTRY:-}" | tr '[:upper:]' '[:lower:]')"
[[ -n "$r" ]] || { echo "error: XLESS_REGISTRY is empty in $f" >&2; exit 1; }
host="${r%%/*}"
case "$host" in
  docker.io|index.docker.io|registry-1.docker.io)
    echo "error: refusing Docker Hub for SDK images ($XLESS_REGISTRY)" >&2; exit 1 ;;
esac
# Images are pushed as $r/<name>. Docker reads a first component without '.' or ':' (other than localhost) as a
# Docker Hub namespace: myuser/xless → docker.io/myuser/xless.
if [[ "$host" != *.* && "$host" != *:* && "$host" != localhost ]]; then
  echo "error: XLESS_REGISTRY '$XLESS_REGISTRY' has no registry host, so Docker would push to Docker Hub (public by default) — use e.g. ghcr.io/<owner>" >&2; exit 1
fi
[[ "${XLESS_REGISTRY_PRIVATE:-}" == "true" ]] || {
  echo "error: set XLESS_REGISTRY_PRIVATE=true in $f only after confirming $r is private (Apple SDK license §2.7)" >&2; exit 1; }
echo "$r"
