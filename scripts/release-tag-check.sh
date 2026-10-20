#!/usr/bin/env bash
# release-tag-check.sh <tag>: exit 0 when <tag> (the latest v* tag, the base of the next version) has a GitHub release.
# Otherwise exit 1 and say why on stderr. The release workflow creates every v* tag together with its release, so a v*
# tag without one was pushed by hand: it would change the next version (scripts/next-version.sh), and the nightly
# refuses to release from it. The `release tags` ruleset (scripts/github-settings.sh) blocks moving and deleting v* tags
# but can't block creating them. Needs `gh` (GH_TOKEN, GH_REPO or a checkout).
set -euo pipefail
tag="${1:-}"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: release-tag-check.sh v<x.y.z>" >&2; exit 2; }
if ! out="$(gh release view "$tag" --json tagName --jq .tagName 2>&1)"; then
  if [[ "$out" == *"release not found"* ]]; then
    echo "the tag $tag has no GitHub release: it was not made by the release workflow (pushed by hand?). Disable the" \
         "'release tags' ruleset, delete the tag (git push origin :refs/tags/$tag), enable the ruleset again." >&2
  else
    echo "cannot look up the release of $tag: $out" >&2
  fi
  exit 1
fi
[[ "$out" == "$tag" ]] || { echo "gh release view $tag answered '$out'" >&2; exit 1; }
