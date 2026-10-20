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

# A squash subject carries " (#N)": shown once, after the scope; the title still counts at 100 characters.
commit -m "feat(cli): $(printf 'x%.0s' $(seq 1 89)) (#42)"; h_pr=$(hash)
pr_out=$(notes "$h_feat2" HEAD)
want_pr="## Features
- $(printf 'x%.0s' $(seq 1 89)) (cli) (#42) ($h_pr)"
[ "$pr_out" = "$want_pr" ] || { echo "FAIL: PR number: '$pr_out'"; fail=1; }

# Markdown in a subject is printed as written.
commit -m 'fix: handle `a_b` and *c* [d](e)'; h_md=$(hash)
md_out=$(notes "$h_pr" HEAD)
[ "$md_out" = "## Fixes
- handle \`a_b\` and *c* [d](e) ($h_md)" ] || { echo "FAIL: markdown: '$md_out'"; fail=1; }

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

# Reverts get their own section; a commit and its revert in the same range are both left out.
commit -m 'chore: base'; h_base=$(hash)
commit -m 'feat: short-lived'; h_short=$(git -C "$repo" rev-parse HEAD)
commit -m 'revert: feat: short-lived' -m "This reverts commit $h_short."
commit -m 'revert(install): feat(install): verify checksums (#9)' -m 'Reverts fmsouza/xless#3'; h_rev=$(hash)
rev_out=$(notes "$h_base" HEAD)
[ "$rev_out" = "## Reverts
- feat(install): verify checksums (install) (#9) ($h_rev)" ] || { echo "FAIL: reverts: '$rev_out'"; fail=1; }

[ "$fail" -eq 0 ] && echo "release-notes: ok"
exit "$fail"
