#!/usr/bin/env bash
# Prints the next SemVer release version, or nothing (exit 0) when no commit since the last release is releasable.
#   scripts/next-version.sh [--first <x.y.z>]        (run in a git checkout)
# The last release is the highest v<x.y.z> tag (by SemVer) reachable from HEAD. Commits after it count when their subject
# is a valid Conventional Commit title (scripts/check-commit-title.sh); invalid subjects are ignored.
#   breaking (`!` before the colon, or a `BREAKING CHANGE:` / `BREAKING-CHANGE:` footer line) -> major, or minor while 0.x
#   feat -> minor    fix, perf -> patch    anything else -> not releasable
# With no v* tag at all, nothing is printed unless --first is given, which prints that version when any commit exists.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/check-commit-title.sh
source "$here/check-commit-title.sh"

first=""
if [ "${1:-}" = "--first" ]; then
  first="${2:-}"
  shift 2 || true
fi
if [ "$#" -ne 0 ] || { [ -n "${first}" ] && [[ ! "$first" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }; then
  echo "usage: next-version.sh [--first <x.y.z>]" >&2
  exit 2
fi

last=$(git tag --merged HEAD --list 'v[0-9]*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)

if [ -z "$last" ]; then
  if [ -n "$first" ] && git rev-parse -q --verify HEAD >/dev/null; then echo "$first"; fi
  exit 0
fi

level=0 # 1 patch, 2 minor, 3 breaking
re='^([a-z]+)(\([^)]*\))?(!)?: '
while IFS= read -r sha; do
  subject=$(cc_subject_title "$(git log -1 --format=%s "$sha")")
  cc_is_valid "$subject" || continue
  [[ "$subject" =~ $re ]]
  type="${BASH_REMATCH[1]}"
  body=$(git log -1 --format=%b "$sha")
  if [ -n "${BASH_REMATCH[3]}" ] || grep -Eq '^BREAKING[ -]CHANGE:' <<<"$body"; then
    l=3
  else
    case "$type" in
      feat) l=2 ;;
      fix | perf) l=1 ;;
      *) l=0 ;;
    esac
  fi
  [ "$l" -gt "$level" ] && level=$l
done < <(git rev-list "$last..HEAD")

[ "$level" -gt 0 ] || exit 0

IFS=. read -r major minor patch <<<"${last#v}"
if [ "$level" -eq 3 ] && [ "$major" -ge 1 ]; then
  echo "$((major + 1)).0.0"
elif [ "$level" -ge 2 ]; then
  echo "$major.$((minor + 1)).0"
else
  echo "$major.$minor.$((patch + 1))"
fi
