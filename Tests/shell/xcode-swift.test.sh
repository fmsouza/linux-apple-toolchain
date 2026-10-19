#!/usr/bin/env bash
# scripts/xcode-swift.sh (Ruling R10): an Xcode's Swift, read from the versions file's table, against a versions file's map.
set -euo pipefail
S="$(cd "$(dirname "$0")/../.." && pwd)/scripts/xcode-swift.sh"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
cat > "$t/versions.env" <<'V'
SWIFT_VERSION=6.4.0
XCODE_APPLE_SWIFT_17C52=6.2.3
XCODE_APPLE_SWIFT_27A266a=6.4
XCODE_APPLE_SWIFT_26X1=6.2.3
XCODE_APPLE_SWIFT_26X2=6.2.3
XCODE_APPLE_SWIFT_26X3=6.2.3
XCODE_APPLE_SWIFT_26X4=6.2.3
XCODE_APPLE_SWIFT_26X5=6.2.3
XCODE_SWIFT_17C52=6.2.3
XCODE_SWIFT_27A266a=6.4.0
XCODE_SWIFT_26X1=6.2.1
XCODE_SWIFT_26X2=6.3.0
XCODE_SWIFT_26X3=6.2.4
XCODE_SWIFT_26X4=6.2.2
SWIFT_TOOLCHAIN_6_2_3_URL_AARCH64=https://example.com/a.tar.gz
SWIFT_TOOLCHAIN_6_2_3_SHA256_AARCH64=aaaa
SWIFT_TOOLCHAIN_6_2_3_URL_X86_64=https://example.com/x.tar.gz
SWIFT_TOOLCHAIN_6_2_3_SHA256_X86_64=xxxx
SWIFT_TOOLCHAIN_6_2_1_URL_AARCH64=https://example.com/a1.tar.gz
SWIFT_TOOLCHAIN_6_2_1_SHA256_AARCH64=a1
SWIFT_TOOLCHAIN_6_2_1_URL_X86_64=https://example.com/x1.tar.gz
SWIFT_TOOLCHAIN_6_2_1_SHA256_X86_64=x1
V
export VERSIONS_ENV="$t/versions.env"
out=$("$S" 17C52 2>/dev/null) || fail "26.2 refused"
[[ "$out" == $'APP_SWIFT_VERSION=6.2.3\nAPP_SWIFT_URL_AARCH64=https://example.com/a.tar.gz\nAPP_SWIFT_SHA256_AARCH64=aaaa\nAPP_SWIFT_URL_X86_64=https://example.com/x.tar.gz\nAPP_SWIFT_SHA256_X86_64=xxxx' ]] || fail "26.2 printed: $out"
# The image's own Swift: nothing to download.
[[ "$("$S" 27A266a 2>/dev/null)" == "APP_SWIFT_VERSION=" ]] || fail "27.0 not the image's own Swift"
# Apple ahead of the open-source tags: a lower patch of the same major.minor is allowed.
"$S" 26X1 >/dev/null 2>&1 || fail "lower patch refused"
# Unknown Xcode, another minor, a higher patch, missing downloads: refused (exit 2) with the reason.
err=$("$S" 99Z9 2>&1 >/dev/null) && fail "unknown Xcode accepted"
[[ "$err" == *"versions.env has no XCODE_APPLE_SWIFT_99Z9"* ]] || fail "unknown Xcode message: $err"
err=$("$S" 26X5 2>&1 >/dev/null) && fail "unmapped Xcode accepted"
[[ "$err" == *"versions.env has no XCODE_SWIFT_26X5"* && "$err" == *"Apple Swift 6.2.3"* ]] || fail "unmapped Xcode message: $err"
"$S" 26X2 >/dev/null 2>&1 && fail "another minor accepted"
"$S" 26X3 >/dev/null 2>&1 && fail "a higher patch accepted"
err=$("$S" 26X4 2>&1 >/dev/null) && fail "missing downloads accepted"
[[ "$err" == *"SWIFT_TOOLCHAIN_6_2_2_URL_AARCH64"* ]] || fail "missing downloads message: $err"
"$S" >/dev/null 2>&1 && fail "no argument accepted"
"$S" 17C52 extra >/dev/null 2>&1 && fail "two arguments accepted"
echo PASS
