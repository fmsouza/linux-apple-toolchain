#!/usr/bin/env bash
# Conventional Commit title check: scripts/check-commit-title.sh <title>
# Exit 0 when valid; exit 1 (message on stderr) when not. Sourcing defines cc_title_regex, cc_is_valid and the helpers
# below (scripts/next-version.sh, scripts/release-notes.sh) and runs nothing.
cc_title_regex='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9._/-]+\))?!?: [^[:space:]].*$'
cc_max_length=100

cc_is_valid() {
  [ "${#1}" -le "$cc_max_length" ] && [[ "$1" =~ $cc_title_regex ]]
}

# GitHub appends " (#N)" to a squash-merged PR title; the title itself is what must be valid (and at most 100 characters).
# cc_subject_title <subject> prints the subject without that trailing PR reference; cc_subject_pr prints "#N" or nothing.
cc_pr_re='^(.*) \(#([0-9]+)\)$'
cc_subject_title() {
  if [[ "$1" =~ $cc_pr_re ]]; then printf '%s' "${BASH_REMATCH[1]}"; else printf '%s' "$1"; fi
}
cc_subject_pr() {
  if [[ "$1" =~ $cc_pr_re ]]; then printf '#%s' "${BASH_REMATCH[2]}"; fi
}

# Reverts (CONTRIBUTING.md, "Reverts"). A `revert:` commit names what it reverts in its body, as `git revert` writes it
# ("This reverts commit <sha>.") or as GitHub's Revert button does ("Reverts <owner>/<repo>#<N>", or "Reverts #<N>": the
# squash commit whose subject ends in " (#<N>)").
# cc_cancelled <range> prints the full SHAs of the commits in <range> that cancel out within it: a commit together with a
# later revert of it in the same range. Walked oldest first; a revert of such a revert (a re-apply) restores the original.
# A revert whose target is outside <range> (already released) cancels nothing: it counts on its own.
cc_cancelled() {
  local range="$1" all sha subject body target n cancelled="" pairs="" prev
  all=$(git rev-list --reverse "$range")
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    subject=$(cc_subject_title "$(git log -1 --format=%s "$sha")")
    cc_is_valid "$subject" || continue
    [[ "$subject" =~ ^revert(\([^\)]*\))?!?:\  ]] || continue
    body=$(git log -1 --format=%b "$sha")
    target=""
    if [[ "$body" =~ This\ reverts\ commit\ ([0-9a-f]{7,40}) ]]; then
      target=$(git rev-parse -q --verify "${BASH_REMATCH[1]}^{commit}" 2>/dev/null || true)
    elif [[ "$body" =~ (^|[[:space:]])Reverts\ ([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)?#([0-9]+) ]]; then
      n="${BASH_REMATCH[3]}"
      target=$(while IFS= read -r c; do
                 if [ -z "$c" ] || [ "$c" = "$sha" ]; then continue; fi
                 [ "$(cc_subject_pr "$(git log -1 --format=%s "$c")")" = "#$n" ] && { echo "$c"; break; }
               done <<<"$all")
    fi
    if [ -z "$target" ] || ! grep -qx "$target" <<<"$all"; then continue; fi
    if grep -qx "$target" <<<"$cancelled"; then
      # Reverting a revert that cancelled something: that something is back, and this pair cancels out instead.
      prev=$(awk -v r="$target" '$1 == r { print $2 }' <<<"$pairs")
      [ -n "$prev" ] || continue
      cancelled=$(grep -vx "$prev" <<<"$cancelled" || true)$'\n'"$sha"
    else
      cancelled="$cancelled"$'\n'"$target"$'\n'"$sha"
      pairs="$pairs"$'\n'"$sha $target"
    fi
  done <<<"$all"
  grep -v '^$' <<<"$cancelled" || true
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" -ne 1 ]; then
    echo "usage: $0 <title>" >&2
    exit 2
  fi
  if cc_is_valid "$1"; then
    exit 0
  fi
  {
    echo "invalid title: $1"
    echo "expected: <type>[(scope)][!]: <description>, at most $cc_max_length characters"
    echo "  type: feat fix docs style refactor perf test build ci chore revert; scope: lower case, e.g. fix(install): verify checksums"
  } >&2
  exit 1
fi
