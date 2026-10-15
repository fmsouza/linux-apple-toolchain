#!/usr/bin/env bash
# Checks scripts/testflight.sh's command construction in dry-run mode (no docker, no network, no secrets).
set -euo pipefail
S="$(cd "$(dirname "$0")/../.." && pwd)/scripts/testflight.sh"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
mkdir -p "$t/proj" "$t/bin"
touch "$t/proj/xless.yml"
printf 'x' > "$t/key.p8"; printf 'x' > "$t/dist.pem"; printf 'ISSUER-SECRET-VALUE' > "$t/issuer"
# A fake docker that knows two contexts, so context selection is testable without a daemon.
cat > "$t/bin/docker" <<'D'
#!/usr/bin/env bash
if [[ "$1 $2" == "context ls" ]]; then printf 'default\ncolima-xless\n'; fi
D
chmod +x "$t/bin/docker"
base=(env -i HOME="$t/home" PATH="$t/bin:/usr/bin:/bin" XLESS_TESTFLIGHT_ENV="$t/none.env" XLESS_TESTFLIGHT_DRY_RUN=1 XLESS_USE_DOCKER=1
      ASC_KEY_ID=KEYID ASC_ISSUER_ID_FILE="$t/issuer" ASC_KEY_P8_FILE="$t/key.p8" XLESS_DIST_KEY_FILE="$t/dist.pem")

out=$("${base[@]}" "$S" "$t/proj" 2>/dev/null) || fail "dry run failed"
[[ "$out" == *"--context colima-xless"* ]] || fail "colima-xless context not preferred: $out"
[[ "$out" == *"xless ship --platform ios"* ]] || fail "missing ship command: $out"
[[ "$out" == *"ISSUER-SECRET-VALUE"* ]] && fail "issuer value leaked"
[[ "$out" == *"/secrets/asc.p8:ro"* && "$out" == *"ASC_KEY_P8_FILE=/secrets/asc.p8"* ]] || fail "p8 not mounted by path: $out"

# explicit context wins, image override, build number override
out=$("${base[@]}" DOCKER_CONTEXT=other XLESS_IMAGE=img:1 XLESS_BUILD_NUMBER=42 "$S" "$t/proj" 2>/dev/null)
[[ "$out" == *"--context other"* && "$out" == *"img:1"* ]] || fail "overrides ignored: $out"
# XLESS_BUILD_NUMBER is passed by name; its value is in the script's environment, not argv
[[ "$out" == *"-e XLESS_BUILD_NUMBER "* ]] || fail "build number not passed by name: $out"

# default build number is a monotonic minutes-since-epoch value
msg=$("${base[@]}" "$S" "$t/proj" 2>&1 >/dev/null) || true
n=$(sed -n 's/.*build number \([0-9]*\)$/\1/p' <<<"$msg" | head -1)
now=$(( $(date +%s) / 60 ))
[[ -n "$n" && $n -ge $((now - 1)) && $n -le $((now + 1)) ]] || fail "default build number '$n' not near $now"

# native mode runs xless in the project directory and forwards extra args
printf '#!/bin/sh\n' > "$t/bin/xless"; chmod +x "$t/bin/xless"
out=$("${base[@]}" XLESS_USE_DOCKER=0 "$S" "$t/proj" --from upload 2>/dev/null)
[[ "$out" == "xless ship --platform ios --from upload " ]] || fail "native command wrong: '$out'"

# every missing variable is a usage error (exit 2) naming the variable
for v in ASC_KEY_ID ASC_ISSUER_ID_FILE ASC_KEY_P8_FILE XLESS_DIST_KEY_FILE; do
  code=0; "${base[@]}" "$v=" "$S" "$t/proj" >/dev/null 2>"$t/err" || code=$?
  [[ $code -eq 2 ]] || fail "missing $v exits $code, want 2"
  grep -q "$v\|ASC_ISSUER_ID" "$t/err" || fail "error does not name $v"
done
# relative secret paths are made absolute before mounting
out=$(cd "$t" && "${base[@]}" ASC_KEY_P8_FILE=key.p8 "$S" proj 2>/dev/null) || fail "relative path run failed"
[[ "$out" == *"-v $t/key.p8:/secrets/asc.p8:ro"* || "$out" == *"-v "*"$t/key.p8:/secrets/asc.p8:ro"* ]] || fail "relative path not resolved: $out"

# missing pieces are named without printing values
"${base[@]}" ASC_KEY_P8_FILE="$t/missing.p8" "$S" "$t/proj" >/dev/null 2>"$t/err" && fail "missing p8 accepted"
grep -q ASC_KEY_P8_FILE "$t/err" || fail "error does not name ASC_KEY_P8_FILE"
"${base[@]}" "$S" "$t/nodir" >/dev/null 2>&1 && fail "missing project accepted"

# env file is sourced
printf 'ASC_KEY_ID=FROMFILE\n' > "$t/f.env"
out=$("${base[@]}" XLESS_TESTFLIGHT_ENV="$t/f.env" XLESS_USE_DOCKER=0 "$S" "$t/proj" 2>/dev/null) || fail "env file run failed"

# exit code is xless's
printf '#!/bin/sh\nexit 17\n' > "$t/bin/xless"
"${base[@]}" XLESS_TESTFLIGHT_DRY_RUN=0 XLESS_USE_DOCKER=0 "$S" "$t/proj" >/dev/null 2>&1 && fail "exit code swallowed"
code=0; "${base[@]}" XLESS_TESTFLIGHT_DRY_RUN=0 XLESS_USE_DOCKER=0 "$S" "$t/proj" >/dev/null 2>&1 || code=$?
[[ $code -eq 17 ]] || fail "exit code $code, want 17"
echo PASS
