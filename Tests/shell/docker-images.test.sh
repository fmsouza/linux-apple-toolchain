#!/usr/bin/env bash
# scripts/docker-images.sh: the one docker recipe for every image. A DOCKER stub records its argv; nothing is built.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
S="$root/scripts/docker-images.sh"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
cat > "$t/docker" <<'D'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$DOCKER_ARGV"
D
chmod +x "$t/docker"
export DOCKER="$t/docker" DOCKER_ARGV="$t/argv"
has() { [[ " $(cat "$DOCKER_ARGV") " == *" $1 "* ]] || fail "$2: '$1' missing from: $(cat "$DOCKER_ARGV")"; }

# base: the platform, the tag, the Dockerfile and every pin the Makefile passed.
"$S" base --arch amd64 --suffix -x 2>/dev/null
has "--platform linux/amd64 --load -t xless-base:local-amd64-x -f docker/Dockerfile.base" base
for k in SWIFT_VERSION XTOOL_VERSION RCODESIGN_VERSION STATIC_SDK_URL STATIC_SDK_SHA256 XTOOL_SHA256_AARCH64 XTOOL_SHA256_X86_64 \
         RCODESIGN_SHA256_AARCH64 RCODESIGN_SHA256_X86_64; do
  grep -q -- "--build-arg $k=." "$DOCKER_ARGV" || fail "base: --build-arg $k missing"
done
grep -q XLESS_FROM "$DOCKER_ARGV" && fail "base compiles from source without --xless-bin"
[[ "$(cat "$DOCKER_ARGV")" == "buildx build "* && "$(cat "$DOCKER_ARGV")" == *" ." ]] || fail "base: context is not the share root: $(cat "$DOCKER_ARGV")"

# base from a prebuilt xless.
mkdir "$t/bin"; : > "$t/bin/xless"
"$S" base --arch arm64 --suffix '' --xless-bin "$t/bin/xless" 2>/dev/null
has "--build-arg XLESS_FROM=prebuilt" prebuilt
has "--build-context xlessbin=$t/bin" prebuilt
has "-t xless-base:local-arm64" prebuilt
: > "$t/bin/other"
"$S" base --arch arm64 --suffix '' --xless-bin "$t/bin/other" >/dev/null 2>&1 && fail "a binary not named xless accepted"
"$S" sdk --arch arm64 --suffix '' --xless-bin "$t/bin/xless" >/dev/null 2>&1 && fail "--xless-bin accepted for sdk"

# sdk: needs the SDK directory and the Xcode build.
rc=0; "$S" sdk --arch arm64 --suffix -x --xcode-build 17C52 >/dev/null 2>&1 || rc=$?
[[ $rc == 2 ]] || fail "sdk without --sdk-dir exited $rc, not 2"
rc=0; "$S" sdk --arch arm64 --suffix -x --sdk-dir d >/dev/null 2>&1 || rc=$?
[[ $rc == 2 ]] || fail "sdk without --xcode-build exited $rc, not 2"
"$S" sdk --arch arm64 --suffix -x --sdk-dir d --xcode-build 17C52 2>/dev/null
has "--build-context sdk=d" sdk
has "--build-arg APP_SWIFT_VERSION=6.2.3" sdk
has "--build-arg BASE=xless-base:local-arm64-x" sdk
has "-t xless:local-arm64-x" sdk
rc=0; "$S" sdk --arch arm64 --suffix -x --sdk-dir d --xcode-build NOPE >/dev/null 2>&1 || rc=$?
[[ $rc == 2 ]] || fail "unknown Xcode build exited $rc, not 2"

# tauri and rn sit on the previous image of the same arch and suffix.
"$S" tauri --arch arm64 --suffix -x 2>/dev/null
has "-t xless-tauri:local-arm64-x" tauri; has "--build-arg BASE=xless:local-arm64-x" tauri
"$S" rn --arch arm64 --suffix -x 2>/dev/null
has "-t xless-rn:local-arm64-x" rn; has "--build-arg BASE=xless-tauri:local-arm64-x" rn

# rn outside a git checkout: v<XLESS_VERSION>-<12 hex of sha256 versions.env><suffix>.
mkdir -p "$t/share"; cp -R "$root/scripts" "$root/versions.env" "$t/share/"
"$t/share/scripts/docker-images.sh" rn --arch arm64 --suffix -x 2>/dev/null
grep -Eq -- "--build-arg XLESS_IMAGE_ID=v0\.0\.0-dev-[0-9a-f]{12}-x( |$)" "$DOCKER_ARGV" || fail "rn image id outside git: $(cat "$DOCKER_ARGV")"
want="$( (sha256sum "$root/versions.env" 2>/dev/null || shasum -a 256 "$root/versions.env") | cut -c1-12)"
has "--build-arg XLESS_IMAGE_ID=v0.0.0-dev-$want-x" "rn id hash"
# Inside the checkout: the commit (skipped where git cannot read it, e.g. a container running as another user).
if [[ "$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)" == "$root" ]]; then
"$S" rn --arch arm64 --suffix -x 2>/dev/null
grep -Eq -- "--build-arg XLESS_IMAGE_ID=[0-9a-f]{12}(-dirty)?-$want-x( |$)" "$DOCKER_ARGV" || fail "rn image id in git: $(cat "$DOCKER_ARGV")"
fi
echo "docker-images.test.sh: ok"
