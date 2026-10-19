#!/usr/bin/env bash
# scripts/ci-passed.sh against a stubbed `gh` whose output is $GH_JSON.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
mkdir -p "$t/bin"
cat > "$t/bin/gh" <<'G'
#!/usr/bin/env bash
echo "$*" > "$GH_ARGS"
[[ "${GH_FAIL:-0}" != 1 ]] || exit 1
printf '%s\n' "$GH_JSON"
G
chmod +x "$t/bin/gh"
sha=$(printf 'a%.0s' $(seq 40))
check() {  # json -> sets rc, err
  rc=0; err=$(PATH="$t/bin:$PATH" GH_ARGS="$t/args" GH_JSON="$1" "$repo/scripts/ci-passed.sh" "$sha" 2>&1 >/dev/null) || rc=$?
}
check '[{"status":"completed","conclusion":"success"}]'
[[ $rc == 0 ]] || fail "success: rc=$rc $err"
grep -qF -- "--workflow pr.yml --commit $sha --event push" "$t/args" || fail "gh args: $(cat "$t/args")"
check '[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"failure"}]'
[[ $rc == 0 ]] || fail "newest success should pass"
check '[{"status":"completed","conclusion":"failure"},{"status":"completed","conclusion":"success"}]'
[[ $rc == 1 && "$err" == *"did not pass"*"failure"* ]] || fail "failure: rc=$rc $err"
check '[{"status":"in_progress","conclusion":""}]'
[[ $rc == 1 && "$err" == *"still running"* ]] || fail "in progress: rc=$rc $err"
check '[{"status":"completed","conclusion":"cancelled"}]'
[[ $rc == 1 && "$err" == *"cancelled"* ]] || fail "cancelled: rc=$rc $err"
check '[]'
[[ $rc == 1 && "$err" == *"no pr workflow run"* ]] || fail "none: rc=$rc $err"
rc=0; err=$(PATH="$t/bin:$PATH" GH_ARGS="$t/args" GH_FAIL=1 "$repo/scripts/ci-passed.sh" "$sha" 2>&1) || rc=$?
[[ $rc == 1 && "$err" == *"cannot list"* ]] || fail "gh failure: rc=$rc $err"
rc=0; "$repo/scripts/ci-passed.sh" nothex >/dev/null 2>&1 || rc=$?
[[ $rc == 2 ]] || fail "bad sha rc=$rc"
echo "ci-passed.test.sh: OK"
