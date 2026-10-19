#!/usr/bin/env bash
# ci-passed.sh <sha>: exit 0 when the newest `pr` workflow run for a push of <sha> to main concluded success.
# Otherwise exit 1 and say why on stderr (no run yet, still running, or failed). Needs `gh` (GH_TOKEN, GH_REPO or a checkout).
# The release workflow calls it so a nightly never publishes a commit whose CI did not pass.
set -euo pipefail
sha="${1:-}"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "usage: ci-passed.sh <40-hex commit sha>" >&2; exit 2; }
runs="$(gh run list --workflow pr.yml --commit "$sha" --event push --limit 20 --json status,conclusion)" \
  || { echo "cannot list the pr workflow runs for $sha" >&2; exit 1; }
# gh prints a compact JSON array, newest run first: look at its first object only (no jq: the CI containers lack it).
first="$(sed -n 's/^\[{\([^}]*\)}.*$/\1/p' <<<"$runs")"
if [[ -z "$first" ]]; then state=none
else
  st="$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' <<<"$first")"
  co="$(sed -n 's/.*"conclusion":"\([^"]*\)".*/\1/p' <<<"$first")"
  state="$st/$co"
fi
case "$state" in
  none) echo "no pr workflow run for push of $sha yet" >&2; exit 1 ;;
  completed/success) echo "CI passed for $sha" ;;
  completed/*) echo "CI did not pass for $sha (conclusion: ${state#completed/})" >&2; exit 1 ;;
  *) echo "CI is still running for $sha (status: ${state%%/*})" >&2; exit 1 ;;
esac
