#!/usr/bin/env bash
# One docker recipe for every image of the chain (xless-base → xless → xless-tauri → xless-rn), for a Mac checkout and a
# Linux install alike. The Makefile targets, scripts/build-images.sh and `xless setup` all build through it.
# Usage: scripts/docker-images.sh <base|sdk|tauri|rn> --arch <arm64|amd64> --suffix <tag-suffix> [--sdk-dir <dir>]
#                                 [--xless-bin <file>] [--xcode-build <build>]
#   Builds <image>:local-<arch><suffix> with `docker buildx build --load`: xless-base, xless, xless-tauri or xless-rn,
#   each on the previous one of the same arch and suffix. Pins come from versions.env next to this script's directory
#   (the repository, or the installed share/xless); that directory is the build context.
#   sdk: --sdk-dir (the exported Darwin SDK) and --xcode-build (its Xcode build; scripts/xcode-swift.sh gives the app
#        Swift toolchain) are required.
#   base: --xless-bin <file named xless>, a linux xless of the same arch, goes into the image instead of one compiled from
#        source (docker/Dockerfile.base XLESS_FROM=prebuilt).
#   rn: XLESS_IMAGE_ID names the image for `xless prepare`'s fingerprint: the commit (with -dirty) in a git checkout, else
#        v<XLESS_VERSION>, then the first 12 hex of the sha256 of versions.env, then the suffix.
#   DOCKER: the docker command (default docker); DOCKER_CONTEXT applies as usual.
set -euo pipefail

die() { echo "docker-images: $*" >&2; exit 2; }
usage="usage: $0 <base|sdk|tauri|rn> --arch <arm64|amd64> --suffix <tag-suffix> [--sdk-dir <dir>] [--xless-bin <file>] [--xcode-build <build>]"
[[ $# -ge 1 ]] || die "$usage"
image="$1"; shift
arch=""; suffix=""; have_suffix=0; sdk_dir=""; xless_bin=""; xcode_build=""
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || die "$1 needs a value"
  case "$1" in
    --arch) arch="$2" ;;
    --suffix) suffix="$2"; have_suffix=1 ;;
    --sdk-dir) sdk_dir="$2" ;;
    --xless-bin) xless_bin="$2" ;;
    --xcode-build) xcode_build="$2" ;;
    *) die "unknown option $1 ($usage)" ;;
  esac
  shift 2
done
case "$image" in base|sdk|tauri|rn) ;; *) die "unknown image '$image' (base, sdk, tauri or rn)" ;; esac
[[ "$arch" == arm64 || "$arch" == amd64 ]] || die "--arch arm64 or amd64 is required"
[[ $have_suffix == 1 ]] || die "--suffix is required (it may be empty: --suffix '')"
if [[ "$image" == sdk ]]; then
  [[ -n "$sdk_dir" ]] || die "sdk needs --sdk-dir <the exported SDK>"
  [[ -n "$xcode_build" ]] || die "sdk needs --xcode-build <the Xcode build the SDK comes from>"
fi
[[ -z "$xless_bin" || "$image" == base ]] || die "--xless-bin applies to base only"
if [[ -n "$xless_bin" ]]; then
  [[ -f "$xless_bin" ]] || die "$xless_bin does not exist"
  [[ "$(basename "$xless_bin")" == xless ]] || die "--xless-bin must be a file named xless (its directory is the build context)"
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
docker_cmd="${DOCKER:-docker}"
set -a; . "$root/versions.env"; set +a
cd "$root"

tag="local-$arch$suffix"
args=(buildx build --platform "linux/$arch" --load -t "xless-$image:$tag")
[[ "$image" != sdk ]] || args=(buildx build --platform "linux/$arch" --load -t "xless:$tag")

case "$image" in
  base)
    args+=(-f docker/Dockerfile.base
      --build-arg "SWIFT_VERSION=$SWIFT_VERSION" --build-arg "XTOOL_VERSION=$XTOOL_VERSION" --build-arg "RCODESIGN_VERSION=$RCODESIGN_VERSION"
      --build-arg "STATIC_SDK_URL=$STATIC_SDK_URL" --build-arg "STATIC_SDK_SHA256=$STATIC_SDK_SHA256"
      --build-arg "XTOOL_SHA256_AARCH64=$XTOOL_SHA256_AARCH64" --build-arg "XTOOL_SHA256_X86_64=$XTOOL_SHA256_X86_64"
      --build-arg "RCODESIGN_SHA256_AARCH64=$RCODESIGN_SHA256_AARCH64" --build-arg "RCODESIGN_SHA256_X86_64=$RCODESIGN_SHA256_X86_64")
    if [[ -n "$xless_bin" ]]; then
      xdir="$(cd "$(dirname "$xless_bin")" && pwd)"
      args+=(--build-arg XLESS_FROM=prebuilt --build-context "xlessbin=$xdir")
    fi ;;
  sdk)
    swift_out="$("$root/scripts/xcode-swift.sh" "$xcode_build")" || exit 2
    args+=(-f docker/Dockerfile.sdk --build-context "sdk=$sdk_dir" --build-arg "BASE=xless-base:$tag")
    while IFS= read -r line; do [[ -z "$line" ]] || args+=(--build-arg "$line"); done <<<"$swift_out" ;;
  tauri)
    args+=(-f docker/Dockerfile.tauri --build-arg "BASE=xless:$tag"
      --build-arg "NODE_VERSION=$NODE_VERSION" --build-arg "NODE_SHA256_ARM64=$NODE_SHA256_ARM64" --build-arg "NODE_SHA256_X64=$NODE_SHA256_X64"
      --build-arg "RUSTUP_VERSION=$RUSTUP_VERSION" --build-arg "RUSTUP_SHA256_AARCH64=$RUSTUP_SHA256_AARCH64" --build-arg "RUSTUP_SHA256_X86_64=$RUSTUP_SHA256_X86_64"
      --build-arg "LIBDMG_HFSPLUS_COMMIT=$LIBDMG_HFSPLUS_COMMIT" --build-arg "LIBDMG_HFSPLUS_SHA256=$LIBDMG_HFSPLUS_SHA256") ;;
  rn)
    if [[ "$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)" == "$root" ]]; then
      id="$(git -C "$root" rev-parse --short=12 HEAD)"
      git -C "$root" diff --quiet HEAD 2>/dev/null || id+="-dirty"
    else
      id="v$XLESS_VERSION"
    fi
    if command -v sha256sum >/dev/null 2>&1; then vsum="$(sha256sum versions.env | cut -d' ' -f1)"; else vsum="$(shasum -a 256 versions.env | cut -d' ' -f1)"; fi
    id+="-${vsum:0:12}$suffix"
    args+=(-f docker/Dockerfile.rn --build-arg "BASE=xless-tauri:$tag"
      --build-arg "SWIFT_VERSION=$SWIFT_VERSION" --build-arg "RN_RUBY_VERSION=$RN_RUBY_VERSION" --build-arg "RN_RUBY_SHA256=$RN_RUBY_SHA256"
      --build-arg "RN_BUNDLER_VERSION=$RN_BUNDLER_VERSION" --build-arg "RN_BUNDLER_SHA256=$RN_BUNDLER_SHA256"
      --build-arg "SWB_TAG=$SWB_TAG" --build-arg "SWB_SHA256=$SWB_SHA256" --build-arg "SWB_DRIVER_SHA256=$SWB_DRIVER_SHA256"
      --build-arg "SWB_LLBUILD_SHA256=$SWB_LLBUILD_SHA256" --build-arg "SWB_TSC_SHA256=$SWB_TSC_SHA256"
      --build-arg "SWB_TOOLS_PROTOCOLS_SHA256=$SWB_TOOLS_PROTOCOLS_SHA256"
      --build-arg "SWB_ARGUMENT_PARSER_VERSION=$SWB_ARGUMENT_PARSER_VERSION" --build-arg "SWB_ARGUMENT_PARSER_SHA256=$SWB_ARGUMENT_PARSER_SHA256"
      --build-arg "SWB_SYSTEM_VERSION=$SWB_SYSTEM_VERSION" --build-arg "SWB_SYSTEM_SHA256=$SWB_SYSTEM_SHA256"
      --build-arg "SWB_SQLITE_VERSION=$SWB_SQLITE_VERSION" --build-arg "SWB_SQLITE_SHA256=$SWB_SQLITE_SHA256"
      --build-arg "HERMES_TAG=$HERMES_TAG" --build-arg "HERMES_SHA256=$HERMES_SHA256" --build-arg "XLESS_IMAGE_ID=$id") ;;
esac
args+=(.)
echo "==> docker-images: xless-$image:$tag" >&2
exec $docker_cmd "${args[@]}"
