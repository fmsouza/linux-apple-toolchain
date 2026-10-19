#!/usr/bin/env bash
# Conventional Commit title check: scripts/check-commit-title.sh <title>
# Exit 0 when valid; exit 1 (message on stderr) when not. Sourcing defines cc_title_regex and cc_is_valid and runs nothing.
cc_title_regex='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9][a-z0-9._/-]*\))?!?: [^[:space:]].*$'
cc_max_length=100

cc_is_valid() {
  [ "${#1}" -le "$cc_max_length" ] && [[ "$1" =~ $cc_title_regex ]]
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
