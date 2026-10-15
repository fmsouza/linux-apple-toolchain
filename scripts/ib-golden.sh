#!/usr/bin/env bash
# Regenerates the ibtool golden storyboardc directories for Tests/IBCorpus. Run on the Mac with Xcode 27.0 (27A266a).
# Usage: scripts/ib-golden.sh [--accept-new-ibtool] [case...]
#   no cases: every Tests/IBCorpus/*.storyboard, using the flag sets from flagsets.json (".cases[case]" or ".default").
# Mirrors Xcode's CompileStoryboard + LinkStoryboards steps (see docs/research/ib-invocation.md).
# Refuses to run unless Xcode build is 27A266a, and unless the live ibtool matches golden/IBTOOL_VERSION
# (pass --accept-new-ibtool to regenerate after a deliberate ibtool change).
# Exits non-zero if ibtool fails or prints any error/warning/notice.
# IB_GOLDEN_OUT=<dir> writes the goldens there instead of Tests/IBCorpus/golden (scripts/ib-parity.sh uses it to check
# for drift); the ibtool guard still compares against the committed Tests/IBCorpus/golden/IBTOOL_VERSION.
# Test hook: IB_GOLDEN_XCODE_BUILD_OVERRIDE replaces the detected Xcode build (only to exercise the guard).
set -euo pipefail
die() { echo "ib-golden: $*" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C="$ROOT/Tests/IBCorpus"; G="$C/golden"; F="${IB_GOLDEN_FLAGSETS:-$C/flagsets.json}"
O="${IB_GOLDEN_OUT:-$G}"
REQUIRED_BUILD="27A266a"
command -v jq >/dev/null || die "jq is required"

accept_new=0; cases=()
for a in "$@"; do
  case "$a" in
    --accept-new-ibtool) accept_new=1 ;;
    -*) die "unknown option: $a" ;;
    *) cases+=("$a") ;;
  esac
done

# Guard 1: pinned Xcode build.
xcv="$(xcodebuild -version)" || die "xcodebuild -version failed"
build="$(printf '%s\n' "$xcv" | sed -n 's/^Build version //p')"
build="${IB_GOLDEN_XCODE_BUILD_OVERRIDE:-$build}"
[[ $build == "$REQUIRED_BUILD" ]] || die "Xcode build is '$build', goldens require $REQUIRED_BUILD; refusing to run"

# Guard 2: ibtool identity vs recorded IBTOOL_VERSION.
ibjson="$(xcrun ibtool --version | plutil -convert json -o - -)" || die "cannot read ibtool --version"
ibline="$(printf '%s' "$ibjson" | jq -er '."com.apple.ibtool.version" | "ibtool \(.["short-bundle-version"]) (\(.["bundle-version"]))"')" \
  || die "cannot parse ibtool --version"
live_version="$(printf '%s\n%s\n' "$ibline" "$xcv")"
if [[ -f $G/IBTOOL_VERSION && $accept_new -eq 0 ]]; then
  [[ "$(cat "$G/IBTOOL_VERSION")" == "$live_version" ]] \
    || die "live ibtool differs from golden/IBTOOL_VERSION; pass --accept-new-ibtool to regenerate"
fi

# flagsets.json validation.
jq -e '(.flagsets|type=="object") and (.default|type=="array" and length>0) and (.cases|type=="object")' "$F" >/dev/null \
  || die "malformed $F (need .flagsets object, non-empty .default array, .cases object)"
bad="$(jq -r '[.flagsets|to_entries[]|select((.value|type!="array") or (.value|length==0) or (.value|any(type!="string")))|.key]|join(",")' "$F")" \
  || die "cannot read $F"
[[ -z $bad ]] || die "empty or non-string-array flagsets: $bad"
bad="$(jq -r '. as $r | [($r.default[], ($r.cases[]|if type=="array" then .[] else "<not-an-array>" end)) | select(. as $n | ($r.flagsets|has($n))|not)] | unique | join(",")' "$F")" \
  || die "cannot read $F"
[[ -z $bad ]] || die "flagset(s) referenced but not defined in .flagsets: $bad"
bad="$(jq -r '[.cases|to_entries[]|select(.value|length==0)|.key]|join(",")' "$F")" || die "cannot read $F"
[[ -z $bad ]] || die "case(s) with empty flagset list: $bad"

if ((${#cases[@]} == 0)); then
  while IFS= read -r f; do cases+=("$(basename "$f" .storyboard)"); done < <(find "$C" -maxdepth 1 -name '*.storyboard' | sort)
fi
((${#cases[@]})) || die "no cases"
for c in "${cases[@]}"; do
  [[ $c =~ ^[A-Za-z0-9._-]+$ && $c != *..* ]] || die "invalid case name: '$c'"
done

# Diagnostic-only flags Xcode passes; proven to have no effect on output (docs/research/ib-invocation.md).
DIAG=(--errors --warnings --notices --output-format human-readable-text)
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$O"

for c in "${cases[@]}"; do
  src="$C/$c.storyboard"; [[ -f $src ]] || die "no such case: $c"
  setsraw="$(jq -er --arg c "$c" '(.cases[$c] // .default)[]' "$F")" || die "cannot read flagsets for $c"
  sets=(); while IFS= read -r s; do sets+=("$s"); done <<<"$setsraw"
  ((${#sets[@]})) || die "no flagsets for $c"
  stage="$T/stage/$c"; mkdir -p "$stage"
  for s in "${sets[@]}"; do
    flagsraw="$(jq -er --arg s "$s" '.flagsets[$s][]' "$F")" || die "cannot read flags for $s"
    flags=(); while IFS= read -r a; do flags+=("$a"); done <<<"$flagsraw"
    ((${#flags[@]})) || die "empty flags for $s"
    w="$T/work/$c/$s"; mkdir -p "$w/bundle"
    # CompileStoryboard
    if ! xcrun ibtool "${DIAG[@]}" --module IBProbe --auto-activate-custom-fonts "${flags[@]}" \
         --output-partial-info-plist "$w/partial.plist" --compile "$w/$c.storyboardc" "$src" >"$w/compile.log" 2>&1 || [[ -s $w/compile.log ]]; then
      echo "ib-golden: ibtool compile reported problems for $c/$s:" >&2; cat "$w/compile.log" >&2; exit 1
    fi
    # LinkStoryboards: ibtool --link <app bundle> <compiled.storyboardc>; the result lands at <app>/<name>.storyboardc (bundle root)
    if ! xcrun ibtool "${DIAG[@]}" --module IBProbe "${flags[@]}" --link "$w/bundle" "$w/$c.storyboardc" >"$w/link.log" 2>&1 || [[ -s $w/link.log ]]; then
      echo "ib-golden: ibtool link reported problems for $c/$s:" >&2; cat "$w/link.log" >&2; exit 1
    fi
    [[ -d $w/bundle/$c.storyboardc ]] || die "link produced no $c.storyboardc for $s"
    cp -R "$w/bundle/$c.storyboardc" "$stage/$s.storyboardc"
  done
  # Whole case succeeded: move into place (never leaves half-written goldens).
  rm -rf "$O/$c.new"; mkdir -p "$O/$c.new"; cp -R "$stage"/. "$O/$c.new"/
  rm -rf "$O/$c"; mv "$O/$c.new" "$O/$c"
  echo "ib-golden: $c (${sets[*]})"
done
printf "%s\n" "$live_version" > "$O/IBTOOL_VERSION.tmp"; mv "$O/IBTOOL_VERSION.tmp" "$O/IBTOOL_VERSION"
