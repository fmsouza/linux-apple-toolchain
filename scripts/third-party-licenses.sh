#!/usr/bin/env bash
# Writes the third-party licence notices a release ships in share/xless/licenses/: one file per package in
# Package.resolved (the LICENSE, and the NOTICE when there is one, from the SwiftPM checkout), plus the Swift runtime
# and the C/C++ libraries the static binary links in (licenses/vendored/, see its README).
#   scripts/third-party-licenses.sh <out-dir>
# XLESS_CHECKOUTS overrides the checkouts directory (default .build/checkouts, filled by `swift build`).
set -euo pipefail
out="${1:?usage: third-party-licenses.sh <out-dir>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
checkouts="${XLESS_CHECKOUTS:-$root/.build/checkouts}"
mkdir -p "$out"

ids=$(sed -n 's/.*"identity" : "\(.*\)",/\1/p' "$root/Package.resolved")
[[ -n "$ids" ]] || { echo "third-party-licenses: no packages in Package.resolved" >&2; exit 1; }
for id in $ids; do
  dir=""
  for d in "$checkouts"/*; do
    [[ -d "$d" ]] || continue
    lower=$(basename "$d" | tr '[:upper:]' '[:lower:]')
    if [[ "$lower" == "$id" ]]; then dir="$d"; break; fi
  done
  [[ -n "$dir" ]] || { echo "third-party-licenses: no checkout of $id in $checkouts (run swift build first)" >&2; exit 1; }
  lic=""
  for n in LICENSE LICENSE.txt LICENSE.md LICENCE COPYING; do [[ -f "$dir/$n" ]] && { lic="$dir/$n"; break; }; done
  [[ -n "$lic" ]] || { echo "third-party-licenses: no licence file in $dir" >&2; exit 1; }
  cp "$lic" "$out/$id.txt"
  for n in NOTICE NOTICE.txt NOTICE.md; do [[ -f "$dir/$n" ]] && { cp "$dir/$n" "$out/$id.NOTICE.txt"; break; }; done
done

# In-repo third-party code: AssetKit (and the LZFSE it embeds), built into xless from ThirdParty/.
cp "$root/ThirdParty/AssetKit/LICENSE" "$out/assetkit.txt"
cp "$root/ThirdParty/AssetKit/Sources/CLZFSE/LICENSE" "$out/lzfse.txt"

# Everything the static Swift SDK links in (musl, the Swift runtime and Foundation, libcurl, libxml2, ICU, zlib, the TLS
# library, ...): verbatim upstream notices vendored in licenses/vendored/, each checked against the sha256 recorded in
# SOURCES.tsv (name, component, version, source URL, sha256) before it is copied.
vendored="$root/licenses/vendored"
while IFS=$'\t' read -r name _component _version _url want; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  [[ -f "$vendored/$name" ]] || { echo "third-party-licenses: $vendored/$name is missing" >&2; exit 1; }
  if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$vendored/$name" | cut -d' ' -f1); else got=$(shasum -a 256 "$vendored/$name" | cut -d' ' -f1); fi
  [[ "$got" == "$want" ]] || { echo "third-party-licenses: $name does not match SOURCES.tsv (got $got, want $want)" >&2; exit 1; }
  cp "$vendored/$name" "$out/$name"
done < "$vendored/SOURCES.tsv"
