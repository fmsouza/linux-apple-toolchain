#!/usr/bin/env bash
# Applies the repository settings for the PR workflow with `gh api`. Idempotent; run by hand by a repository admin, never by CI.
#   scripts/github-settings.sh [owner/repo]     (default: fmsouza/linux-apple-toolchain)
set -euo pipefail
repo="${1:-fmsouza/linux-apple-toolchain}"
ruleset_name="main protection"

# Squash merges only; the squash commit is the PR title and body; merged branches are deleted.
gh api -X PATCH "repos/$repo" \
  -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY \
  -F delete_branch_on_merge=true >/dev/null

# Ruleset on main: PR required (0 approvals), the six checks required, no force pushes, no deletion.
ruleset=$(cat <<JSON
{
  "name": "$ruleset_name",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false, "require_last_push_approval": false,
        "required_review_thread_resolution": false } },
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [
          { "context": "title" },
          { "context": "linux-tests (x86_64)" },
          { "context": "linux-tests (arm64)" },
          { "context": "package (x86_64)" },
          { "context": "package (arm64)" },
          { "context": "shellcheck" } ] } },
    { "type": "non_fast_forward" },
    { "type": "deletion" }
  ]
}
JSON
)

id=$(gh api "repos/$repo/rulesets" --jq "[.[] | select(.name == \"$ruleset_name\") | .id] | first // empty")
if [ -n "$id" ]; then
  echo "$ruleset" | gh api -X PUT "repos/$repo/rulesets/$id" --input - >/dev/null
  echo "updated ruleset $id on $repo"
else
  echo "$ruleset" | gh api -X POST "repos/$repo/rulesets" --input - >/dev/null
  echo "created ruleset on $repo"
fi
