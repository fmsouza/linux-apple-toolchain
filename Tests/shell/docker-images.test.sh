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
for k in SWIFT_IMAGE XTOOL_VERSION RCODESIGN_VERSION STATIC_SDK_URL STATIC_SDK_SHA256 XTOOL_SHA256_AARCH64 XTOOL_SHA256_X86_64 \
         RCODESIGN_SHA256_AARCH64 RCODESIGN_SHA256_X86_64; do
  grep -q -- "--build-arg $k=." "$DOCKER_ARGV" || fail "base: --build-arg $k missing"
done
grep -q XLESS_FROM "$DOCKER_ARGV" && fail "base compiles from source without --xless-bin"
[[ "$(cat "$DOCKER_ARGV")" == "buildx build "* && "$(cat "$DOCKER_ARGV")" == *" ." ]] || fail "base: context is not the share root: $(cat "$DOCKER_ARGV")"

# base from a prebuilt xless: a fake ELF header (64 bytes, e_machine at offset 18: 183 aarch64, 62 x86-64).
fake_elf() { { printf '\177ELF\002\001\001'; head -c 11 /dev/zero; printf "$2"; head -c 44 /dev/zero; } > "$1"; }
mkdir "$t/bin" "$t/bin64"
fake_elf "$t/bin/xless" '\267\000'
fake_elf "$t/bin64/xless" '\076\000'
"$S" base --arch arm64 --suffix '' --xless-bin "$t/bin/xless" 2>/dev/null
has "--build-arg XLESS_FROM=prebuilt" prebuilt
has "--build-context xlessbin=$t/bin" prebuilt
has "-t xless-base:local-arm64" prebuilt
: > "$t/bin/other"
"$S" base --arch arm64 --suffix '' --xless-bin "$t/bin/other" >/dev/null 2>&1 && fail "a binary not named xless accepted"
"$S" sdk --arch arm64 --suffix '' --xless-bin "$t/bin/xless" >/dev/null 2>&1 && fail "--xless-bin accepted for sdk"
# The binary's ELF machine must be --arch's: an x86-64 xless in an arm64 image (or the reverse) is refused.
"$S" base --arch amd64 --suffix '' --xless-bin "$t/bin64/xless" 2>/dev/null
has "-t xless-base:local-amd64" "prebuilt amd64"
rm -f "$DOCKER_ARGV"
rc=0; "$S" base --arch amd64 --suffix '' --xless-bin "$t/bin/xless" 2>"$t/err" || rc=$?
[[ $rc == 2 ]] || fail "an aarch64 xless for amd64 exited $rc, not 2"
grep -q "aarch64" "$t/err" && grep -q "amd64" "$t/err" || fail "the mismatch message: $(cat "$t/err")"
[[ ! -e "$DOCKER_ARGV" ]] || fail "docker ran for a mismatched binary"
rc=0; "$S" base --arch arm64 --suffix '' --xless-bin "$t/bin64/xless" >/dev/null 2>&1 || rc=$?
[[ $rc == 2 ]] || fail "an x86-64 xless for arm64 exited $rc, not 2"
mkdir "$t/bintxt"; echo 'not elf' > "$t/bintxt/xless"
rc=0; "$S" base --arch arm64 --suffix '' --xless-bin "$t/bintxt/xless" >/dev/null 2>&1 || rc=$?
[[ $rc == 2 ]] || fail "a non-ELF xless exited $rc, not 2"

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
# Inside the checkout: the commit. safe.directory lets git read a checkout owned by another user (CI's container).
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0="$root" "$S" rn --arch arm64 --suffix -x 2>/dev/null
grep -Eq -- "--build-arg XLESS_IMAGE_ID=[0-9a-f]{12}(-dirty)?-$want-x( |$)" "$DOCKER_ARGV" || fail "rn image id in git: $(cat "$DOCKER_ARGV")"
echo "docker-images.test.sh: ok"
