#!/usr/bin/env bash
# ci-passed.sh <sha>: exit 0 when the newest `pr` workflow run for a push of <sha> to main concluded success.
# Otherwise exit 1 and say why on stderr (no run yet, still running, or failed). Needs `gh` (GH_TOKEN, GH_REPO or a checkout)
# and jq. The release workflow calls it so a nightly never publishes a commit whose CI did not pass.
set -euo pipefail
sha="${1:-}"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "usage: ci-passed.sh <40-hex commit sha>" >&2; exit 2; }
runs="$(gh run list --workflow pr.yml --commit "$sha" --event push --limit 20 --json status,conclusion)" \
  || { echo "cannot list the pr workflow runs for $sha" >&2; exit 1; }
state="$(jq -r 'if length == 0 then "none" else (.[0].status + "/" + (.[0].conclusion // "")) end' <<<"$runs")"
case "$state" in
  none) echo "no pr workflow run for push of $sha yet" >&2; exit 1 ;;
  completed/success) echo "CI passed for $sha" ;;
  completed/*) echo "CI did not pass for $sha (conclusion: ${state#completed/})" >&2; exit 1 ;;
  *) echo "CI is still running for $sha (status: ${state%%/*})" >&2; exit 1 ;;
esac
