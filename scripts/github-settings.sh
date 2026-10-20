#!/usr/bin/env bash
# Applies the repository settings for the PR workflow with `gh api`. Idempotent; run by hand by a repository admin, never by CI.
#   scripts/github-settings.sh [owner/repo]     (default: fmsouza/xless)
set -euo pipefail
repo="${1:-fmsouza/xless}"
ruleset_name="main protection"
tag_ruleset_name="release tags"

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

# apply_ruleset <name> <json>: creates the ruleset, or updates the one of that name.
apply_ruleset() {
  local name="$1" json="$2" id
  id=$(gh api "repos/$repo/rulesets" --jq "[.[] | select(.name == \"$name\") | .id] | first // empty")
  if [ -n "$id" ]; then
    echo "$json" | gh api -X PUT "repos/$repo/rulesets/$id" --input - >/dev/null
    echo "updated ruleset '$name' ($id) on $repo"
  else
    echo "$json" | gh api -X POST "repos/$repo/rulesets" --input - >/dev/null
    echo "created ruleset '$name' on $repo"
  fi
}
apply_ruleset "$ruleset_name" "$ruleset"

# Ruleset on release tags (v*): scripts/next-version.sh computes the next release from them, so none may be moved or
# deleted, by anyone. Creation stays open: the release workflow creates each tag with its GITHUB_TOKEN
# (`gh release create --target`), and a repository owned by a personal account can't name GitHub Actions as a bypass
# actor (the API answers "must be part of the ruleset source or owner organization"). A v* tag pushed by hand is caught
# instead by release.yml's plan job, which refuses to release when the latest v* tag has no GitHub release.
# To delete a wrong tag, disable this ruleset first.
tag_ruleset=$(cat <<JSON
{
  "name": "$tag_ruleset_name",
  "target": "tag",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/tags/v*"], "exclude": [] } },
  "rules": [
    { "type": "update" },
    { "type": "deletion" },
    { "type": "non_fast_forward" }
  ]
}
JSON
)
apply_ruleset "$tag_ruleset_name" "$tag_ruleset"
