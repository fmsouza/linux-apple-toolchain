#!/usr/bin/env bash
# The release's assets, beside the two tarballs the build legs made:
#   scripts/release-assets.sh <version> <dist>
# <dist> must hold exactly xless-<version>-linux-x86_64.tar.gz and xless-<version>-linux-arm64.tar.gz. Writes
# <dist>/SHA256SUMS (sha256sum's format, sorted by name) and copies scripts/install.sh to <dist>/install.sh. The release
# workflow's verify and publish jobs both run it, so what is installed before publishing is what is published.
set -euo pipefail
version="${1:-}" dist="${2:-}"
die() { echo "release-assets: $*" >&2; exit 1; }
[[ -n "$version" && -n "$dist" ]] || { echo "usage: release-assets.sh <version> <dist>" >&2; exit 2; }
[[ -d "$dist" ]] || die "no directory $dist"
root="$(cd "$(dirname "$0")/.." && pwd)"
want=("xless-$version-linux-arm64.tar.gz" "xless-$version-linux-x86_64.tar.gz")
got=()
while IFS= read -r f; do got+=("$f"); done < <(cd "$dist" && find . -maxdepth 1 -name '*.tar.gz' | sed 's#^\./##' | LC_ALL=C sort)
[[ "${got[*]-}" == "${want[*]}" ]] || die "$dist holds [${got[*]-}], expected [${want[*]}]"
if command -v sha256sum >/dev/null 2>&1; then (cd "$dist" && sha256sum "${want[@]}") > "$dist/SHA256SUMS"
else (cd "$dist" && shasum -a 256 "${want[@]}") > "$dist/SHA256SUMS"; fi
cp "$root/scripts/install.sh" "$dist/install.sh"
cat "$dist/SHA256SUMS"
