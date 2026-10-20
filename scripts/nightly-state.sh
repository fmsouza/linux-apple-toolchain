#!/usr/bin/env bash
# Checks that the nightly release workflow is enabled, and re-enables it when GitHub turned it off for inactivity:
#   scripts/nightly-state.sh [workflow]        (default release.yml; GH_TOKEN / GH_REPO as for gh)
# GitHub disables scheduled workflows in a public repository after 60 days without activity (state
# disabled_inactivity). Then this enables it again (the REST API's workflow enable; the token needs actions: write)
# and warns.
# A workflow a maintainer disabled by hand (disabled_manually) is left alone, with a warning. Exit 0 unless gh fails.
set -euo pipefail
wf="${1:-release.yml}"
state="$(gh api "repos/{owner}/{repo}/actions/workflows/$wf" --jq .state)"
case "$state" in
  active)
    echo "$wf is active" ;;
  disabled_inactivity)
    gh api -X PUT "repos/{owner}/{repo}/actions/workflows/$wf/enable" >/dev/null
    echo "::warning::$wf had been disabled by GitHub after 60 days without activity; re-enabled it. Commits merged meanwhile are released by the next nightly (or now: gh workflow run $wf --ref main)." ;;
  disabled_manually)
    echo "::warning::$wf is disabled (by hand): no nightly releases. Re-enable it with: gh workflow enable $wf" ;;
  *)
    echo "::warning::$wf is in state '$state': no nightly releases. See docs/maintainers.md#the-nightly-may-be-switched-off" ;;
esac
