#!/usr/bin/env bash
# scripts/nightly-state.sh against a stubbed `gh` that reports $GH_STATE and logs its calls.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
mkdir -p "$t/bin"
cat > "$t/bin/gh" <<'G'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
[[ "${GH_FAIL:-0}" != 1 ]] || exit 1
[[ "$*" == "api repos/{owner}/{repo}/actions/workflows/"*" --jq .state" ]] && printf '%s\n' "$GH_STATE"
exit 0
G
chmod +x "$t/bin/gh"
run() {  # state -> sets rc, out
  : > "$t/log"; rc=0
  out=$(PATH="$t/bin:$PATH" GH_LOG="$t/log" GH_STATE="$1" "$repo/scripts/nightly-state.sh" 2>&1) || rc=$?
}
run active
[[ $rc == 0 && "$out" == "release.yml is active" ]] || fail "active: rc=$rc $out"
grep -qxF 'api repos/{owner}/{repo}/actions/workflows/release.yml --jq .state' "$t/log" || fail "view args: $(cat "$t/log")"
grep -q 'enable' "$t/log" && fail "active: enabled again"

run disabled_inactivity
[[ $rc == 0 && "$out" == "::warning::release.yml had been disabled by GitHub after 60 days"* ]] || fail "inactivity: rc=$rc $out"
grep -qxF 'api -X PUT repos/{owner}/{repo}/actions/workflows/release.yml/enable' "$t/log" || fail "inactivity: not re-enabled: $(cat "$t/log")"

run disabled_manually
[[ $rc == 0 && "$out" == *"::warning::release.yml is disabled (by hand)"*"gh workflow enable release.yml"* ]] || fail "manual: rc=$rc $out"
grep -q 'enable' "$t/log" && fail "manual: a maintainer's choice was overridden"

run deleted
[[ $rc == 0 && "$out" == *"state 'deleted'"* ]] || fail "other state: rc=$rc $out"

rc=0; PATH="$t/bin:$PATH" GH_LOG="$t/log" GH_FAIL=1 "$repo/scripts/nightly-state.sh" >/dev/null 2>&1 || rc=$?
[[ $rc != 0 ]] || fail "a gh failure passed"
echo "nightly-state.test.sh: OK"
