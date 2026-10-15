#!/usr/bin/env bash
# Builds, signs and uploads an iOS project and delivers it to TestFlight (`xless ship --platform ios`).
# Usage: scripts/testflight.sh <project-dir> [extra xless ship args...]     (or: make testflight PROJECT=<dir>)
#
# Where it runs
#   macOS            inside the xless Linux image, through docker.
#   Linux            natively when `xless` is on PATH, otherwise through docker.
#   XLESS_USE_DOCKER=1 forces docker; XLESS_USE_DOCKER=0 forces native.
#
# Configuration comes from the environment, and from a local file that is sourced first when it exists:
#   $XLESS_TESTFLIGHT_ENV, default ~/.config/xless/testflight.env   (keep it out of git; it holds paths and IDs only)
# Variables (see docs/README.md#one-command-testflight):
#   ASC_KEY_ID               App Store Connect API key ID                      (required)
#   ASC_ISSUER_ID_FILE       file holding the issuer ID   (or ASC_ISSUER_ID)   (required)
#   ASC_KEY_P8_FILE          the API key .p8 file                              (required)
#   XLESS_DIST_KEY_FILE      the Apple Distribution private key (PEM)          (required)
#   XLESS_IMAGE              docker image; default xless:local-<arch>
#   DOCKER_CONTEXT           docker context; default colima-xless if it exists, else the current one
#   XLESS_BUILD_NUMBER       build number; default minutes since 1970 (monotonic across machines)
#   XLESS_TESTFLIGHT_DRY_RUN=1   print what would run (no secret values are ever printed) and exit
# With docker, secret files and the project must live under a directory the docker VM can see (on macOS typically somewhere under
# $HOME; Colima shares $HOME, Docker Desktop shares the directories listed in its file-sharing settings).
# The exit code is xless's (2 for a usage or configuration error in this script).
set -euo pipefail

die() { echo "testflight: $*" >&2; exit 2; }

[[ $# -ge 1 ]] || die "usage: $0 <project-dir> [extra xless ship args...]"
PROJECT="$1"; shift
[[ -f "$PROJECT/xless.yml" ]] || die "$PROJECT/xless.yml not found (is '$PROJECT' an xless project?)"
PROJECT="$(cd "$PROJECT" && pwd)"

ENV_FILE="${XLESS_TESTFLIGHT_ENV:-$HOME/.config/xless/testflight.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a   # export what the file defines, so `docker run -e NAME` can see it
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

[[ -n "${ASC_KEY_ID:-}" ]] || die "set ASC_KEY_ID in the environment or $ENV_FILE"
[[ -n "${ASC_ISSUER_ID_FILE:-}${ASC_ISSUER_ID:-}" ]] || die "set ASC_ISSUER_ID_FILE (or ASC_ISSUER_ID) in the environment or $ENV_FILE"
# Secret file paths are made absolute (docker -v needs absolute host paths) and must be readable.
abs_file() {   # NAME: resolve $NAME to an absolute path in place
  local v="$1" p="${!1}"
  [[ -r "$p" ]] || die "$v points to a file that does not exist or is unreadable"
  [[ "$p" == /* ]] || p="$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
  printf -v "$v" '%s' "$p"
}
for v in ASC_KEY_P8_FILE XLESS_DIST_KEY_FILE; do
  [[ -n "${!v:-}" ]] || die "set $v in the environment or $ENV_FILE"
  abs_file "$v"
done
if [[ -n "${ASC_ISSUER_ID_FILE:-}" ]]; then abs_file ASC_ISSUER_ID_FILE; fi

export XLESS_BUILD_NUMBER="${XLESS_BUILD_NUMBER:-$(( $(date +%s) / 60 ))}"

use_docker=0
case "${XLESS_USE_DOCKER:-auto}" in
  1) use_docker=1 ;;
  0) use_docker=0 ;;
  auto) if [[ "$(uname -s)" == Darwin ]] || ! command -v xless >/dev/null 2>&1; then use_docker=1; fi ;;
  *) die "XLESS_USE_DOCKER must be 0, 1 or unset" ;;
esac

run() {
  if [[ "${XLESS_TESTFLIGHT_DRY_RUN:-0}" == 1 ]]; then printf '%q ' "$@"; echo; return 0; fi
  "$@"
}

echo "==> TestFlight: build number $XLESS_BUILD_NUMBER" >&2
set +e
if [[ $use_docker == 1 ]]; then
  command -v docker >/dev/null 2>&1 || die "docker is not installed (and no native xless is on PATH)"
  ctx="${DOCKER_CONTEXT:-}"
  if [[ -z "$ctx" ]] && docker context ls --format '{{.Name}}' 2>/dev/null | grep -qx 'colima-xless'; then ctx=colima-xless; fi
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
  image="${XLESS_IMAGE:-xless:local-$arch}"
  args=(docker)
  [[ -z "$ctx" ]] || args+=(--context "$ctx")
  args+=(run --rm -v "$PROJECT:/work" -w /work
    -v "$ASC_KEY_P8_FILE:/secrets/asc.p8:ro" -v "$XLESS_DIST_KEY_FILE:/secrets/dist-key.pem:ro"
    -e ASC_KEY_ID -e XLESS_BUILD_NUMBER
    -e ASC_KEY_P8_FILE=/secrets/asc.p8 -e XLESS_DIST_KEY_FILE=/secrets/dist-key.pem)
  if [[ -n "${ASC_ISSUER_ID_FILE:-}" ]]; then
    args+=(-v "$ASC_ISSUER_ID_FILE:/secrets/asc-issuer-id:ro" -e ASC_ISSUER_ID_FILE=/secrets/asc-issuer-id)
  else
    args+=(-e ASC_ISSUER_ID)   # by name: the value never appears in the process list
  fi
  args+=("$image" xless ship --platform ios "$@")
  run "${args[@]}"
else
  cd "$PROJECT"
  run xless ship --platform ios "$@"
fi
code=$?
set -e
if [[ $code -eq 0 ]]; then echo "==> TestFlight delivery finished (build number $XLESS_BUILD_NUMBER)" >&2
else echo "==> xless exited with code $code" >&2; fi
exit $code
