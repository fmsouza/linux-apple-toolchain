#!/usr/bin/env bash
# scripts/check-commit-title.sh: the Conventional Commit title check (no docker, no network, no secrets).
set -euo pipefail
cd "$(dirname "$0")/../.."
script=scripts/check-commit-title.sh
fail=0

ok() {
  if ! bash "$script" "$1" >/dev/null 2>&1; then echo "FAIL: expected valid: '$1'"; fail=1; fi
}
bad() {
  local err rc=0
  err=$(bash "$script" "$1" 2>&1 >/dev/null) || rc=$?
  if [ "$rc" -ne 1 ]; then echo "FAIL: expected exit 1, got $rc: '$1'"; fail=1; return; fi
  case "$err" in "invalid title: $1"*) ;; *) echo "FAIL: stderr lacks 'invalid title: $1': $err"; fail=1 ;; esac
}

ok 'feat: xless setup'
ok 'fix(install): verify checksums'
ok 'feat!: drop Xcode 26.2'
ok 'ci(release): nightly'
ok 'revert: feat: x'
ok 'fix(-x): scope may start with punctuation'
ok 'fix(_x.y/z-1): any of a-z0-9._/-'

bad 'Add setup'
bad 'feat:missing space'
bad 'feature: x'
bad 'feat(Scope): x'
bad 'feat: '
bad "feat: $(printf 'x%.0s' $(seq 1 95))"   # 101 characters
bad "Merge branch 'main'"

# Sourcing defines the helpers and runs nothing.
out=$(bash -c 'source scripts/check-commit-title.sh; cc_is_valid "feat: a" && ! cc_is_valid "nope" && [ -n "$cc_title_regex" ] && echo defined')
[ "$out" = defined ] || { echo "FAIL: sourcing: '$out'"; fail=1; }

[ "$fail" -eq 0 ] && echo "check-commit-title: ok"
exit "$fail"
