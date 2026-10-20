#!/usr/bin/env bash
# Prints Markdown release notes for the commits in <from-ref>..<to-ref> (an empty from-ref means all history up to to-ref).
#   scripts/release-notes.sh <from-ref|""> <to-ref>
# Sections, in this order, each omitted when empty: Breaking changes, Features, Fixes, Performance, Reverts. One bullet
# per commit: "- <description> (<scope>) (#<PR>) (<short hash>)", newest first. Commits with an invalid title are
# skipped, and so are a commit and a revert of it that are both in the range (they cancel out: cc_cancelled).
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

breaking="" features="" fixes="" perf="" reverts=""
re='^([a-z]+)(\(([^)]*)\))?(!)?: (.*)$'
cancelled=$(cc_cancelled "$range")
while IFS= read -r sha; do
  if [ -n "$cancelled" ] && grep -qx "$sha" <<<"$cancelled"; then continue; fi
  raw=$(git log -1 --format=%s "$sha")
  subject=$(cc_subject_title "$raw")
  cc_is_valid "$subject" || continue
  pr=$(cc_subject_pr "$raw")
  [[ "$subject" =~ $re ]]
  type="${BASH_REMATCH[1]}" scope="${BASH_REMATCH[3]}" bang="${BASH_REMATCH[4]}" desc="${BASH_REMATCH[5]}"
  line="- $desc"
  [ -z "$scope" ] || line="$line ($scope)"
  [ -z "$pr" ] || line="$line ($pr)"
  line="$line ($(git rev-parse --short=7 "$sha"))"
  body=$(git log -1 --format=%b "$sha")
  if [ -n "$bang" ] || grep -Eq '^BREAKING[ -]CHANGE:' <<<"$body"; then
    breaking="$breaking$line"$'\n'
    continue
  fi
  case "$type" in
    feat) features="$features$line"$'\n' ;;
    fix) fixes="$fixes$line"$'\n' ;;
    perf) perf="$perf$line"$'\n' ;;
    revert) reverts="$reverts$line"$'\n' ;;
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
section "Reverts" "$reverts"
printf '%s' "$out"
