#!/usr/bin/env bash
# scripts/release-notes.sh: Markdown release notes from Conventional Commit titles (temp git repos only).
set -euo pipefail
cd "$(dirname "$0")/../.."
script="$PWD/scripts/release-notes.sh"
repo="$(mktemp -d)"
trap 'rm -rf "$repo"' EXIT
fail=0
git -C "$repo" init -q
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name t
git -C "$repo" config commit.gpgsign false
commit() { git -C "$repo" commit -q --allow-empty "$@"; }
notes() { (cd "$repo" && bash "$script" "$@"); }
hash() { git -C "$repo" rev-parse --short=7 HEAD; }

commit -m 'chore: init'
git -C "$repo" tag v0.1.0
commit -m 'fix(install): verify checksums'; h_fix=$(hash)
commit -m 'feat(cli): add xless docker'; h_feat=$(hash)
commit -m 'perf: faster hashing'; h_perf=$(hash)
commit -m 'docs: not listed'
commit -m 'Merge something odd'
commit -m 'refactor(cli)!: rename flags' -m 'BREAKING CHANGE: flags renamed'; h_br=$(hash)
commit -m 'fix: footer break' -m 'BREAKING CHANGE: x'; h_br2=$(hash)
commit -m 'feat: second feature'; h_feat2=$(hash)

out=$(notes v0.1.0 HEAD)
want="## Breaking changes
- footer break ($h_br2)
- rename flags (cli) ($h_br)

## Features
- second feature ($h_feat2)
- add xless docker (cli) ($h_feat)

## Fixes
- verify checksums (install) ($h_fix)

## Performance
- faster hashing ($h_perf)"
if [ "$out" != "$want" ]; then
  echo "FAIL: notes differ"; diff <(echo "$want") <(echo "$out") || true; fail=1
fi

# Empty sections are omitted.
only=$(notes v0.1.0 "$h_fix")
[ "$only" = "## Fixes
- verify checksums (install) ($h_fix)" ] || { echo "FAIL: single section: '$only'"; fail=1; }

# An empty from-ref means the whole history up to <to-ref>.
all=$(notes "" "$h_fix")
case "$all" in "## Fixes"*) ;; *) echo "FAIL: empty from-ref: '$all'"; fail=1 ;; esac

# Nothing releasable prints nothing.
none=$(notes "$h_perf" "$h_perf")
[ -z "$none" ] || { echo "FAIL: expected empty, got '$none'"; fail=1; }

[ "$fail" -eq 0 ] && echo "release-notes: ok"
exit "$fail"
