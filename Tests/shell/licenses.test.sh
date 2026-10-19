#!/usr/bin/env bash
# The vendored third-party notices (licenses/vendored/): every row of SOURCES.tsv has its file with the recorded sha256,
# every file is listed, the components that are statically linked into xless are all covered, and
# scripts/third-party-licenses.sh ships each of them byte for byte (and refuses a modified one).
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
v="$repo/licenses/vendored"
tsv="$v/SOURCES.tsv"
[[ -f "$tsv" ]] || fail "no $tsv"

listed=""
while IFS=$'\t' read -r name component version url want; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  [[ -n "$component" && -n "$version" && "$url" == https://* && "$want" =~ ^[0-9a-f]{64}$ ]] || fail "malformed row for $name"
  [[ -s "$v/$name" ]] || fail "$name is missing or empty"
  [[ "$(sha "$v/$name")" == "$want" ]] || fail "$name does not match its recorded sha256"
  grep -q "$name" "$v/README.md" || fail "$name is not described in README.md"
  listed="$listed $name"
done < "$tsv"
for f in "$v"/*; do
  b=$(basename "$f")
  [[ "$b" == SOURCES.tsv || "$b" == README.md ]] && continue
  case " $listed " in *" $b "*) ;; *) fail "$b is not listed in SOURCES.tsv" ;; esac
done

# Every statically linked component has a notice (the list is the one recorded in README.md, from the link map).
for c in swift musl curl libxml2 zlib icu boringssl; do
  awk -F'\t' -v c="$c" '$2 == c { f = 1 } END { exit !f }' "$tsv" || fail "no notice for $c"
done

# The script ships them verbatim, and refuses a vendored file that no longer matches.
mkdir -p "$t/checkouts"
for id in $(sed -n 's/.*"identity" : "\(.*\)",/\1/p' "$repo/Package.resolved"); do
  mkdir -p "$t/checkouts/$id"; echo "licence of $id" > "$t/checkouts/$id/LICENSE"
done
XLESS_CHECKOUTS="$t/checkouts" bash "$repo/scripts/third-party-licenses.sh" "$t/out" >/dev/null
for n in $listed; do cmp -s "$v/$n" "$t/out/$n" || fail "$n was not shipped verbatim"; done

mkdir -p "$t/fake/scripts" "$t/fake/licenses"
cp "$repo/scripts/third-party-licenses.sh" "$t/fake/scripts/"; cp "$repo/Package.resolved" "$t/fake/"; cp -R "$v" "$t/fake/licenses/vendored"
first=$(echo $listed | cut -d' ' -f1)
echo tampered >> "$t/fake/licenses/vendored/$first"
XLESS_CHECKOUTS="$t/checkouts" bash "$t/fake/scripts/third-party-licenses.sh" "$t/out2" >/dev/null 2>&1 && fail "a modified notice was shipped"
echo "licenses.test.sh: OK"
