#!/usr/bin/env bash
# Builds, signs and uploads an iOS project and delivers it to TestFlight (`xless ship --platform ios`).
# Usage: scripts/testflight.sh <project-dir> [extra xless ship args...]     (or: make testflight PROJECT=<dir>)
#        scripts/testflight.sh --config <overlay.yml> [extra xless ship args...]   (or: make testflight CONFIG=<overlay.yml>)
#
# --config: a Tauri v2 app described by an overlay file (docs/tauri.md) instead of an xless.yml project.
#   The app source is the overlay's `source:` (`~` expanded, relative to the overlay file's directory), or $XLESS_SOURCE
#   when set, which wins. `source:` must be a plain top-level `source: <path>` line (optionally quoted, with a trailing
#   comment); anything fancier (flow style, anchors, multi-line) is not read by this script: set XLESS_SOURCE instead.
#   The overlay path may start with `~/`. The source is never written to.
#   The app's build runs third-party code (npm scripts, build.rs, proc-macros), so it never runs next to a secret.
#   Three steps, each its own container (or process, natively):
#     1. xless tauri next-build      with the App Store Connect key only: the next dated build number (read-only).
#                                    Skipped when XLESS_BUILD_NUMBER is set, or when resuming after build.
#     2. xless ship --to finalize    WITHOUT any secret mount or variable: prepare, build, assets, finalize, with
#                                    XLESS_BUILD_NUMBER from step 1.
#     3. xless ship --from sign      with the secrets: sign, package, upload (no build code runs here).
#   --from/--to among the extra args select which steps run. In docker:
#     the source           mounted read-only at /source           and passed as --source /source
#     the overlay's folder mounted read-only at /config           and passed as --config /config/<file>
#       (the whole folder, so a relative `privacyManifest:` or `assets:` in the overlay resolves; `source:` would
#        resolve inside /config too, which is why --source overrides it). Keep the overlay in its own directory: the
#        script refuses an overlay directory that holds the env file or a secret file.
#     ~/.cache/xless/work (steps 2 and 3) and ~/.cache/xless/downloads (step 2) at /cache/work and /cache/downloads
#     volumes xless-rustup and xless-cargo at /cache/rustup and /cache/cargo (step 2; Rust toolchains survive between runs)
#   The image defaults to xless-tauri:local-<arch>. XLESS_BUILD_NUMBER is not defaulted: the overlay's `build:` decides
#   (`dated` asks App Store Connect for the next number in step 1). When set it is passed to steps 2 and 3.
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
#   XLESS_IMAGE              docker image; default xless:local-<arch> (xless-tauri:local-<arch> with --config)
#   DOCKER_CONTEXT           docker context; default colima-xless if it exists, else the current one
#   XLESS_BUILD_NUMBER       build number; default minutes since 1970 (monotonic across machines); not defaulted with --config
#   XLESS_TESTFLIGHT_DRY_RUN=1   print what would run (no secret values are ever printed) and exit
# With docker, secret files and the project must live under a directory the docker VM can see (on macOS typically somewhere under
# $HOME; Colima shares $HOME, Docker Desktop shares the directories listed in its file-sharing settings).
# The exit code is xless's (2 for a usage or configuration error in this script).
set -euo pipefail

die() { echo "testflight: $*" >&2; exit 2; }

usage="usage: $0 <project-dir> [extra xless ship args...]   or   $0 --config <overlay.yml> [extra args...]"
[[ $# -ge 1 ]] || die "$usage"
OVERLAY=""
PROJECT=""
if [[ "$1" == --config ]]; then
  [[ $# -ge 2 ]] || die "$usage"
  OVERLAY="$2"; shift 2
  [[ $# -eq 0 || "$1" == -* ]] || die "--config replaces <project-dir>; give one or the other"
  case "$OVERLAY" in "~/"*) OVERLAY="$HOME/${OVERLAY#\~/}" ;; esac   # e.g. `make testflight CONFIG=~/…` under zsh
  [[ -f "$OVERLAY" ]] || die "overlay $OVERLAY not found"
  OVERLAY="$(cd "$(dirname "$OVERLAY")" && pwd)/$(basename "$OVERLAY")"
else
  PROJECT="$1"; shift
  for a in "$@"; do [[ "$a" != --config && "$a" != --config=* ]] || die "--config replaces <project-dir>; give one or the other"; done
  [[ -f "$PROJECT/xless.yml" ]] || die "$PROJECT/xless.yml not found (is '$PROJECT' an xless project?)"
  PROJECT="$(cd "$PROJECT" && pwd)"
fi

ENV_FILE="${XLESS_TESTFLIGHT_ENV:-$HOME/.config/xless/testflight.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a   # export what the file defines, so `docker run -e NAME` can see it
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

SOURCE=""
if [[ -n "$OVERLAY" ]]; then
  SOURCE="${XLESS_SOURCE:-}"
  if [[ -z "$SOURCE" ]]; then
    # the top-level `source:` line: drop a trailing comment and surrounding quotes
    SOURCE="$(sed -n 's/^source:[[:space:]]*//p' "$OVERLAY" | head -1 | sed -E "s/[[:space:]]+#.*$//; s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/")"
    [[ -n "$SOURCE" ]] || die "$OVERLAY has no source: (set it, or set XLESS_SOURCE)"
  fi
  case "$SOURCE" in "~") SOURCE="$HOME" ;; "~/"*) SOURCE="$HOME/${SOURCE#\~/}" ;; esac
  [[ "$SOURCE" == /* ]] || SOURCE="$(dirname "$OVERLAY")/$SOURCE"
  [[ -d "$SOURCE" ]] || die "the app source $SOURCE does not exist"
  SOURCE="$(cd "$SOURCE" && pwd)"
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

# The overlay's directory is mounted into the container that runs the app's build code: no secret may live below it.
physical() {   # PATH: absolute path with every symlink (the file's own and its directories') resolved
  local p="$1" t n=0
  while [[ -L "$p" && $n -lt 40 ]]; do t="$(readlink "$p")"; [[ "$t" == /* ]] || t="$(dirname "$p")/$t"; p="$t"; n=$((n + 1)); done
  printf '%s/%s' "$(cd -P "$(dirname "$p")" && pwd -P)" "$(basename "$p")"
}
if [[ -n "$OVERLAY" ]]; then
  overlay_dir="$(cd -P "$(dirname "$OVERLAY")" && pwd -P)"
  for v in ENV_FILE ASC_KEY_P8_FILE XLESS_DIST_KEY_FILE ASC_ISSUER_ID_FILE; do
    f="${!v:-}"
    [[ -n "$f" && -e "$f" ]] || continue
    [[ "$(physical "$f")" != "$overlay_dir"/* ]] || die "$v ($f) is inside the overlay's directory $overlay_dir, which is mounted into the build container; keep the overlay in its own directory, away from secrets"
  done
fi

# With --config the overlay's `build:` decides (dated by default); an explicit XLESS_BUILD_NUMBER still wins.
if [[ -z "$OVERLAY" ]]; then export XLESS_BUILD_NUMBER="${XLESS_BUILD_NUMBER:-$(( $(date +%s) / 60 ))}"; fi

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

finish() {   # CODE: report and exit with xless's exit code
  if [[ $1 -eq 0 ]]; then echo "==> TestFlight delivery finished" >&2
  else echo "==> xless exited with code $1" >&2; fi
  exit "$1"
}

if [[ $use_docker == 1 ]]; then
  command -v docker >/dev/null 2>&1 || die "docker is not installed (and no native xless is on PATH)"
  ctx="${DOCKER_CONTEXT:-}"
  if [[ -z "$ctx" ]] && docker context ls --format '{{.Name}}' 2>/dev/null | grep -qx 'colima-xless'; then ctx=colima-xless; fi
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
  docker_run=(docker)
  [[ -z "$ctx" ]] || docker_run+=(--context "$ctx")
  docker_run+=(run --rm)
  # Secrets by path or by name: values never appear on a command line.
  asc_secrets=(-v "$ASC_KEY_P8_FILE:/secrets/asc.p8:ro" -e ASC_KEY_ID -e ASC_KEY_P8_FILE=/secrets/asc.p8)
  if [[ -n "${ASC_ISSUER_ID_FILE:-}" ]]; then
    asc_secrets+=(-v "$ASC_ISSUER_ID_FILE:/secrets/asc-issuer-id:ro" -e ASC_ISSUER_ID_FILE=/secrets/asc-issuer-id)
  else
    asc_secrets+=(-e ASC_ISSUER_ID)   # by name: the value never appears in the process list
  fi
  dist_secret=(-v "$XLESS_DIST_KEY_FILE:/secrets/dist-key.pem:ro" -e XLESS_DIST_KEY_FILE=/secrets/dist-key.pem)
fi

if [[ -z "$OVERLAY" ]]; then
  # A project directory: one `xless ship`. Secrets are mounted, and xless scrubs them from the environment of the tools
  # it runs, but the files stay readable to package code (SwiftPM plugins and macros) built in the same container.
  echo "==> TestFlight: build number $XLESS_BUILD_NUMBER" >&2
  set +e
  if [[ $use_docker == 1 ]]; then
    run "${docker_run[@]}" -v "$PROJECT:/work" -w /work "${asc_secrets[@]}" "${dist_secret[@]}" -e XLESS_BUILD_NUMBER \
      "${XLESS_IMAGE:-xless:local-$arch}" xless ship --platform ios "$@"
  else
    cd "$PROJECT"
    run xless ship --platform ios "$@"
  fi
  code=$?
  set -e
  finish $code
fi

# --config: the three steps of the header. --from/--to are placed by this script; other extra args go to both ship steps.
from=build; to=upload; extra=(); given_build=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from|--to) [[ $# -ge 2 ]] || die "$1 needs a stage"; if [[ "$1" == --from ]]; then from="$2"; else to="$2"; fi; shift 2 ;;
    --from=*) from="${1#--from=}"; shift ;;
    --to=*) to="${1#--to=}"; shift ;;
    --build-number|--build-number=*) given_build=1; extra+=("$1"); shift ;;
    *) extra+=("$1"); shift ;;
  esac
done
stages=(prepare build assets finalize sign package upload)
index() { local i; for i in "${!stages[@]}"; do [[ "${stages[$i]}" != "$1" ]] || { echo "$i"; return 0; }; done
  die "unknown stage '$1' (use one of: ${stages[*]})"; }
fi_="$(index "$from")"; ti="$(index "$to")"
[[ $fi_ -le $ti ]] || die "--to $to comes before --from $from"

if [[ $use_docker == 1 ]]; then
  image="${XLESS_IMAGE:-xless-tauri:local-$arch}"
  cache="$HOME/.cache/xless"
  [[ "${XLESS_TESTFLIGHT_DRY_RUN:-0}" == 1 ]] || mkdir -p "$cache/work" "$cache/downloads"
  app=(-v "$SOURCE:/source:ro" -v "$(dirname "$OVERLAY"):/config:ro")
  xl=(--config "/config/$(basename "$OVERLAY")" --source /source)
else
  # native: --source only when XLESS_SOURCE overrides the overlay's own `source:`
  xl=(--config "$OVERLAY"); [[ -z "${XLESS_SOURCE:-}" ]] || xl+=(--source "$SOURCE")
  # step 2 runs without the secret variables (xless also scrubs them from its tools); the files stay on disk
  scrub=(env); for v in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8 XLESS_DIST_KEY XLESS_DEVID_KEY; do scrub+=(-u "$v" -u "${v}_FILE"); done
fi
bn=(); [[ -z "${XLESS_BUILD_NUMBER:-}" ]] || bn=(-e XLESS_BUILD_NUMBER)

# Step 1: the build number, only for a run that starts (later stages read the one recorded in the work copy).
if [[ -z "${XLESS_BUILD_NUMBER:-}" && $given_build == 0 && $fi_ -le 1 ]]; then
  echo "==> TestFlight: step 1/3, next build number (App Store Connect, read-only)" >&2
  if [[ $use_docker == 1 ]]; then cmd=("${docker_run[@]}" "${app[@]}" "${asc_secrets[@]}" "$image" xless tauri next-build "${xl[@]}")
  else cmd=(xless tauri next-build "${xl[@]}"); fi
  if [[ "${XLESS_TESTFLIGHT_DRY_RUN:-0}" == 1 ]]; then
    run "${cmd[@]}"; XLESS_BUILD_NUMBER="<next-build>"
  else
    set +e; out="$("${cmd[@]}")"; code=$?; set -e
    [[ $code -eq 0 ]] || finish $code
    XLESS_BUILD_NUMBER="$(printf '%s\n' "$out" | tail -1)"
    [[ "$XLESS_BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "xless tauri next-build printed '$XLESS_BUILD_NUMBER', not a build number"
  fi
  export XLESS_BUILD_NUMBER
  bn=(-e XLESS_BUILD_NUMBER)
fi
if [[ -n "${XLESS_BUILD_NUMBER:-}" ]]; then echo "==> TestFlight: build number $XLESS_BUILD_NUMBER" >&2
elif [[ $given_build == 1 ]]; then echo "==> TestFlight: build number from --build-number" >&2
else echo "==> TestFlight: build number recorded in the work copy" >&2; fi

# Step 2: the build, with no secret in reach.
if [[ $fi_ -le 3 ]]; then
  bto="$to"; [[ $ti -le 3 ]] || bto=finalize
  echo "==> TestFlight: step 2/3, $from to $bto (no secrets)" >&2
  set +e
  if [[ $use_docker == 1 ]]; then
    run "${docker_run[@]}" "${app[@]}" -v "$cache/work:/cache/work" -v "$cache/downloads:/cache/downloads" -e XLESS_CACHE=/cache \
      -v xless-rustup:/cache/rustup -v xless-cargo:/cache/cargo -e "XLESS_SOURCE_ORIGIN=$SOURCE" ${bn[@]+"${bn[@]}"} \
      "$image" xless ship --platform ios "${xl[@]}" --from "$from" --to "$bto" ${extra[@]+"${extra[@]}"}
  else
    run "${scrub[@]}" xless ship --platform ios "${xl[@]}" --from "$from" --to "$bto" ${extra[@]+"${extra[@]}"}
  fi
  code=$?
  set -e
  [[ $code -eq 0 ]] || finish $code
fi

# Step 3: sign, package, upload with the secrets; no build code runs here.
if [[ $ti -ge 4 ]]; then
  sfrom="$from"; [[ $fi_ -ge 4 ]] || sfrom=sign
  echo "==> TestFlight: step 3/3, $sfrom to $to" >&2
  set +e
  if [[ $use_docker == 1 ]]; then
    run "${docker_run[@]}" "${app[@]}" -v "$cache/work:/cache/work" "${asc_secrets[@]}" "${dist_secret[@]}" ${bn[@]+"${bn[@]}"} \
      "$image" xless ship --platform ios "${xl[@]}" --from "$sfrom" --to "$to" ${extra[@]+"${extra[@]}"}
  else
    run xless ship --platform ios "${xl[@]}" --from "$sfrom" --to "$to" ${extra[@]+"${extra[@]}"}
  fi
  code=$?
  set -e
  finish $code
fi
echo "==> TestFlight: stopped after $to (--to), nothing delivered" >&2
exit 0
