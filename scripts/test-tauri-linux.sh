#!/usr/bin/env bash
# Builds samples/HelloTauri on Linux (in the xless-tauri image) through build, assets and finalize, then compares the
# finalize output with samples/HelloTauri/reference/reference.json, ignoring the known gaps in
# samples/HelloTauri/reference/allowed-gaps.txt. Exits non-zero on any other difference or on any failed stage.
# No signing, no App Store Connect: the build number is explicit, so no dated-build lookup happens.
#   make test-tauri-linux
# Variables: XLESS_IMAGE (default xless-tauri:local-<arch>), DOCKER_CONTEXT (default colima-xless if it exists).
# The repository is mounted read-only; the work copy lives in the xless-work volume, Rust toolchains in xless-rustup and
# xless-cargo (the first run downloads them and builds the Rust code, which takes a few minutes; later runs are faster).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
ctx="${DOCKER_CONTEXT:-}"
if [[ -z "$ctx" ]] && docker context ls --format '{{.Name}}' 2>/dev/null | grep -qx 'colima-xless'; then ctx=colima-xless; fi
case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
image="${XLESS_IMAGE:-xless-tauri:local-$arch}"
args=(docker)
[[ -z "$ctx" ]] || args+=(--context "$ctx")

# The in-container script reads the same XLESS_BUILD_NUMBER from the environment, never contacting App Store Connect. The overlay
# is `build: dated`, so the override is a dated build of the sample's version (1.0.0).
"${args[@]}" run --rm -i -v "$root":/repo:ro -v xless-work:/cache/work -v xless-rustup:/cache/rustup -v xless-cargo:/cache/cargo \
  -e XLESS_BUILD_NUMBER=1.0.0.2026010101 "$image" bash -s <<'IN'
set -euo pipefail
o=/repo/samples/HelloTauri/xless.overlay.example.yml
s=/repo/samples/HelloTauri
r=/repo/samples/HelloTauri/reference
# prepare, build, assets, finalize; ship prints each stage's output directory, finalize's last
final=$(xless ship --config "$o" --source "$s" --platform ios --to finalize | tail -1)
echo "==> comparing $final with the reference"
xless tauri compare "$r/reference.json" "$final" --allow-file "$r/allowed-gaps.txt"
echo "==> HelloTauri matches the Mac reference (known gaps: $r/allowed-gaps.txt)"
IN
