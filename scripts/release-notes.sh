#!/usr/bin/env bash
# Prints Markdown release notes for the commits in <from-ref>..<to-ref> (an empty from-ref means all history up to to-ref).
#   scripts/release-notes.sh <from-ref|""> <to-ref>
# Sections, in this order, each omitted when empty: Breaking changes, Features, Fixes, Performance. One bullet per
# commit: "- <description> (<scope>) (<short hash>)", newest first. Commits with an invalid title are skipped.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/check-commit-title.sh
source "$here/check-commit-title.sh"

if [ "$#" -ne 2 ]; then
  echo 'usage: release-notes.sh <from-ref|""> <to-ref>' >&2
  exit 2
fi
from="$1" to="$2"
range="$to"
[ -z "$from" ] || range="$from..$to"

breaking="" features="" fixes="" perf=""
re='^([a-z]+)(\(([^)]*)\))?(!)?: (.*)$'
while IFS= read -r sha; do
  subject=$(git log -1 --format=%s "$sha")
  cc_is_valid "$subject" || continue
  [[ "$subject" =~ $re ]]
  type="${BASH_REMATCH[1]}" scope="${BASH_REMATCH[3]}" bang="${BASH_REMATCH[4]}" desc="${BASH_REMATCH[5]}"
  line="- $desc"
  [ -z "$scope" ] || line="$line ($scope)"
  line="$line ($(git rev-parse --short=7 "$sha"))"
  if [ -n "$bang" ] || git log -1 --format=%b "$sha" | grep -Eq '^BREAKING[ -]CHANGE:'; then
    breaking="$breaking$line"$'\n'
    continue
  fi
  case "$type" in
    feat) features="$features$line"$'\n' ;;
    fix) fixes="$fixes$line"$'\n' ;;
    perf) perf="$perf$line"$'\n' ;;
  esac
done < <(git rev-list "$range")

out=""
section() { # <title> <lines>
  [ -n "$2" ] || return 0
  [ -z "$out" ] || out="$out"$'\n'
  out="$out## $1"$'\n'"$2"
}
section "Breaking changes" "$breaking"
section "Features" "$features"
section "Fixes" "$fixes"
section "Performance" "$perf"
printf '%s' "$out"
