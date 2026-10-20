#!/usr/bin/env bash
# scripts/release-tag-check.sh against a stubbed `gh` (GH_MODE: found, missing or down).
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
mkdir -p "$t/bin"
cat > "$t/bin/gh" <<'G'
#!/usr/bin/env bash
echo "$*" > "$GH_ARGS"
case "$GH_MODE" in
  found) echo "$3" ;;
  missing) echo "release not found" >&2; exit 1 ;;
  *) echo "HTTP 502: Bad Gateway" >&2; exit 1 ;;
esac
G
chmod +x "$t/bin/gh"
check() {  # mode tag -> rc, err
  rc=0; err=$(PATH="$t/bin:$PATH" GH_ARGS="$t/args" GH_MODE="$1" "$repo/scripts/release-tag-check.sh" "$2" 2>&1) || rc=$?
}
check found v0.1.1
[[ $rc == 0 ]] || fail "found: rc=$rc $err"
[[ "$(cat "$t/args")" == "release view v0.1.1 --json tagName --jq .tagName" ]] || fail "gh args: $(cat "$t/args")"
check missing v0.2.0
[[ $rc == 1 && "$err" == *"v0.2.0 has no GitHub release"*"ruleset"* ]] || fail "missing: rc=$rc $err"
check down v0.2.0
[[ $rc == 1 && "$err" == *"cannot look up"*"502"* ]] || fail "gh down: rc=$rc $err"
check found nightly
[[ $rc == 2 ]] || fail "a non-release tag: rc=$rc"
echo "release-tag-check.test.sh: OK"
