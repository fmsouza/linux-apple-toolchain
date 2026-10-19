#!/usr/bin/env bash
# Conventional Commit title check: scripts/check-commit-title.sh <title>
# Exit 0 when valid; exit 1 (message on stderr) when not. Sourcing defines cc_title_regex and cc_is_valid and runs nothing.
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
