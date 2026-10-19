#!/usr/bin/env bash
# scripts/next-version.sh: the next SemVer from Conventional Commit titles (temp git repos only; no network).
set -euo pipefail
cd "$(dirname "$0")/../.."
script="$PWD/scripts/next-version.sh"
base="$(mktemp -d)"
trap 'rm -rf "$base"' EXIT
fail=0
n=0

# repo: starts a fresh repo in $PWD-of-subshell-free style; sets $repo.
repo() {
  n=$((n + 1))
  repo="$base/r$n"
  mkdir "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name t
  git -C "$repo" config commit.gpgsign false
}
commit() { git -C "$repo" commit -q --allow-empty "$@"; }
tag() { git -C "$repo" tag "$1"; }
expect() { # <label> <expected> [script args]
  local label="$1" want="$2" got
  shift 2
  got=$(cd "$repo" && bash "$script" "$@")
  if [ "$got" != "$want" ]; then echo "FAIL: $label: expected '$want', got '$got'"; fail=1; fi
}

repo; commit -m 'feat: a'
expect 'no tags, no --first' ''
expect 'no tags, --first' '0.1.0' --first 0.1.0

repo; commit -m 'chore: init'; tag v0.1.0; commit -m 'docs: a'; commit -m 'chore: b'
expect 'docs and chore only' ''

repo; commit -m 'chore: init'; tag v0.1.0; commit -m 'fix: a'
expect 'fix' '0.1.1'

repo; commit -m 'chore: init'; tag v0.1.0; commit -m 'feat: a'; commit -m 'fix: b'
expect 'feat and fix' '0.2.0'

repo; commit -m 'chore: init'; tag v0.3.4; commit -m 'feat!: a'
expect 'breaking bang on 0.x' '0.4.0'

repo; commit -m 'chore: init'; tag v1.2.3; commit -m 'feat(cli)!: a'
expect 'breaking bang with scope on 1.x' '2.0.0'

repo; commit -m 'chore: init'; tag v1.2.3; commit -m 'fix: a' -m 'BREAKING CHANGE: x'
expect 'BREAKING CHANGE footer on 1.x' '2.0.0'

repo; commit -m 'chore: init'; tag v1.2.3; commit -m 'fix: a' -m 'BREAKING-CHANGE: x'
expect 'BREAKING-CHANGE footer on 1.x' '2.0.0'

repo; commit -m 'chore: init'; tag v0.3.4; commit -m 'fix: a' -m 'BREAKING CHANGE: x'
expect 'breaking footer on 0.x' '0.4.0'

repo; commit -m 'chore: init'; tag v1.2.3; commit -m 'fix: a' -m 'Mentions BREAKING CHANGE: in prose, not a footer'
expect 'footer must start the line' '1.2.4'

repo; commit -m 'chore: init'; tag v1.2.3; commit -m 'perf: a'
expect 'perf' '1.2.4'

repo; commit -m 'chore: init'; tag v1.2.3; commit -m 'feat: a'
expect 'feat on 1.x' '1.3.0'

repo; commit -m 'chore: init'; tag v0.1.0; commit -m 'Add a thing'
expect 'non-conventional alone' ''
repo; commit -m 'chore: init'; tag v1.2.3; commit -m 'Add a thing'; commit -m 'Fix: Capitalised' -m 'BREAKING CHANGE: ignored with its invalid subject'
expect 'non-conventional ignored' ''

repo; commit -m 'chore: init'; tag v1.2.3; commit -m 'fix: a'; tag v1.2.4
expect 'HEAD already tagged' ''

repo; commit -m 'chore: init'; tag v0.9.0; commit -m 'chore: x'; tag v0.10.0; commit -m 'fix: a'
expect 'v0.10.0 beats v0.9.0' '0.10.1'

repo; commit -m 'chore: init'; tag v0.2.0; commit -m 'fix: a'; tag nightly-x; tag notes
expect 'non-v tags ignored' '0.2.1'

# A tag on another branch is not reachable from HEAD and is not the base.
repo; commit -m 'chore: init'; tag v0.1.0
git -C "$repo" checkout -q -b side; commit -m 'chore: s'; tag v0.5.0
git -C "$repo" checkout -q -; commit -m 'fix: a'
expect 'unreachable tag ignored' '0.1.1'

# A squash-merge body can carry the footer.
repo; commit -m 'chore: init'; tag v1.0.0; commit -m 'feat: a' -m '- detail' -m 'BREAKING CHANGE: gone'
expect 'footer in a squash body' '2.0.0'

# GitHub appends " (#N)" on squash: a 100-character title stays valid.
title100="feat: $(printf 'x%.0s' $(seq 1 94))"
repo; commit -m 'chore: init'; tag v0.1.0; commit -m "$title100 (#123)"
expect '100-char title plus PR suffix' '0.2.0'
repo; commit -m 'chore: init'; tag v0.1.0; commit -m "${title100}y (#123)"
expect '101-char title is still invalid' ''
repo; commit -m 'chore: init'; tag v0.1.0; commit -m 'fix(cli): a (#7)'
expect 'short title plus PR suffix' '0.1.1'

# A prerelease-looking tag is not a release.
repo; commit -m 'chore: init'; tag v0.9.0; commit -m 'chore: x'; tag v1.0.0-rc.1; commit -m 'fix: a'
expect 'prerelease tag ignored' '0.9.1'

# BREAKING CHANGE in a subject (not a footer) does not count.
repo; commit -m 'chore: init'; tag v1.2.3; commit -m 'fix: BREAKING CHANGE: not a footer'
expect 'breaking text in subject' '1.2.4'

# --first applies only when there is no tag.
repo; commit -m 'chore: init'; tag v0.1.0; commit -m 'fix: a'
expect '--first ignored when tagged' '0.1.1' --first 5.0.0

repo; commit -m 'docs: a'
expect '--first prints with any commit' '0.1.0' --first 0.1.0

if (cd "$repo" && bash "$script" --first nonsense >/dev/null 2>&1); then echo "FAIL: --first nonsense accepted"; fail=1; fi

[ "$fail" -eq 0 ] && echo "next-version: ok"
exit "$fail"
