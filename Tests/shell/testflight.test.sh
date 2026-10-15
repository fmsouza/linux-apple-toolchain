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
# --config: Tauri overlay instead of a project directory, in three steps (next-build, build without secrets, ship from sign)
mkdir -p "$t/ov/app" "$t/home/.cache/xless"
cat > "$t/ov/my.overlay.yml" <<'Y'
type: tauri
source: app            # relative to this file
bundleID: com.example.x
Y
printf 'p' > "$t/ov/PrivacyInfo.xcprivacy"
line() { grep -F -- "$1" <<<"$out" || true; }   # the dry-run command line of one step
out=$("${base[@]}" "$S" --config "$t/ov/my.overlay.yml" 2>/dev/null) || fail "--config dry run failed"
[[ $(wc -l <<<"$out") -eq 3 ]] || fail "want three steps: $out"
s1=$(line "xless tauri next-build"); s2=$(line "--to finalize"); s3=$(line "--from sign")
[[ "$s1" == *"xless tauri next-build --config /config/my.overlay.yml --source /source " ]] || fail "step 1 wrong: $s1"
[[ "$s2" == *"xless ship --platform ios --config /config/my.overlay.yml --source /source --from build --to finalize "* ]] || fail "step 2 wrong: $s2"
[[ "$s3" == *"xless ship --platform ios --config /config/my.overlay.yml --source /source --from sign --to upload "* ]] || fail "step 3 wrong: $s3"
for l in "$s1" "$s2" "$s3"; do
  [[ "$l" == *"-v $t/ov/app:/source:ro"* ]] || fail "source not mounted from the overlay: $l"
  [[ "$l" == *"-v $t/ov:/config:ro"* ]] || fail "overlay directory not mounted: $l"
  [[ "$l" == *"--context colima-xless"* && "$l" == *"xless-tauri:local-"* ]] || fail "context or tauri image: $l"
  [[ "$l" != *":/work "* ]] || fail "project mount used with --config: $l"
done
# step 2 runs the app's build code: no secret mount, no secret variable
[[ "$s2" != *"/secrets/"* && "$s2" != *"ASC_"* && "$s2" != *"XLESS_DIST_KEY"* ]] || fail "secrets reach the build step: $s2"
[[ "$s2" == *"-v $t/home/.cache/xless/work:/cache/work"* && "$s2" == *"-v $t/home/.cache/xless/downloads:/cache/downloads"* ]] || fail "caches not mounted: $s2"
[[ "$s2" == *"xless-rustup:/cache/rustup"* && "$s2" == *"xless-cargo:/cache/cargo"* ]] || fail "toolchain volumes missing: $s2"
[[ "$s2" == *"XLESS_CACHE=/cache"* && "$s2" == *"XLESS_SOURCE_ORIGIN=$t/ov/app"* ]] || fail "XLESS_CACHE/XLESS_SOURCE_ORIGIN not set: $s2"
[[ "$s2" == *"-e XLESS_BUILD_NUMBER "* && "$s3" == *"-e XLESS_BUILD_NUMBER "* ]] || fail "step 1's build number not passed by name: $out"
# step 1 has the App Store Connect key only; step 3 has every secret and the work copy
[[ "$s1" == *"/secrets/asc.p8:ro"* && "$s1" == *"-e ASC_KEY_ID"* && "$s1" != *"dist-key"* && "$s1" != *"/cache/"* ]] || fail "step 1 mounts: $s1"
[[ "$s3" == *"/secrets/asc.p8:ro"* && "$s3" == *"/secrets/dist-key.pem:ro"* && "$s3" == *"ASC_ISSUER_ID_FILE=/secrets/asc-issuer-id"* ]] || fail "step 3 secrets: $s3"
[[ "$s3" == *"-v $t/home/.cache/xless/work:/cache/work"* && "$s3" != *"xless-cargo"* && "$s3" != *"/cache/downloads"* ]] || fail "step 3 mounts: $s3"
[[ "$out" == *"ISSUER-SECRET-VALUE"* ]] && fail "issuer value leaked"
# no default build number: dated decides in step 1
msg=$("${base[@]}" "$S" --config "$t/ov/my.overlay.yml" 2>&1 >/dev/null) || true
[[ "$msg" =~ "build number "[0-9] ]] && fail "build number defaulted with --config: $msg"
# an explicit XLESS_BUILD_NUMBER (or --build-number) skips step 1 and is passed on
out=$("${base[@]}" XLESS_BUILD_NUMBER=1.0.0.2026101507 "$S" --config "$t/ov/my.overlay.yml" 2>/dev/null)
[[ "$out" != *"next-build"* && $(wc -l <<<"$out") -eq 2 ]] || fail "XLESS_BUILD_NUMBER did not skip step 1: $out"
[[ "$(line "--to finalize")" == *"-e XLESS_BUILD_NUMBER "* && "$(line "--from sign")" == *"-e XLESS_BUILD_NUMBER "* ]] || fail "explicit XLESS_BUILD_NUMBER not passed: $out"
out=$("${base[@]}" "$S" --config "$t/ov/my.overlay.yml" --build-number 1.0.0.2026101507 2>/dev/null)
[[ "$out" != *"next-build"* && "$out" != *"-e XLESS_BUILD_NUMBER"* && "$(line "--to finalize")" == *"--to finalize --build-number 1.0.0.2026101507"* ]] || fail "--build-number: $out"
# --from/--to choose the steps; XLESS_SOURCE wins over source:; other extra args go to both ship steps
out=$("${base[@]}" XLESS_SOURCE="$t/proj" "$S" --config "$t/ov/my.overlay.yml" --from upload 2>/dev/null)
[[ $(wc -l <<<"$out") -eq 1 && "$out" == *"-v $t/proj:/source:ro"* && "$out" == *"--source /source --from upload --to upload "* ]] || fail "XLESS_SOURCE/--from upload: $out"
out=$("${base[@]}" "$S" --config "$t/ov/my.overlay.yml" --to finalize 2>/dev/null)
[[ $(wc -l <<<"$out") -eq 2 && "$out" == *"next-build"* && "$out" == *"--from build --to finalize "* ]] || fail "--to finalize: $out"
out=$("${base[@]}" "$S" --config "$t/ov/my.overlay.yml" --from=assets --to=package --verbose 2>/dev/null)
[[ $(wc -l <<<"$out") -eq 2 && "$out" != *"next-build"* ]] || fail "--from assets runs step 1 or the wrong steps: $out"
[[ "$(line "--to finalize")" == *"--from assets --to finalize --verbose "* && "$(line "--from sign")" == *"--from sign --to package --verbose "* ]] || fail "--from assets --to package: $out"
code=0; "${base[@]}" "$S" --config "$t/ov/my.overlay.yml" --from upload --to build >/dev/null 2>&1 || code=$?
[[ $code -eq 2 ]] || fail "--to before --from exits $code, want 2"
code=0; "${base[@]}" "$S" --config "$t/ov/my.overlay.yml" --from ib >/dev/null 2>&1 || code=$?
[[ $code -eq 2 ]] || fail "unknown stage exits $code, want 2"
# ~ expands in source: and in the overlay path (make testflight CONFIG=~/… under zsh passes it unexpanded)
mkdir -p "$t/home/src" "$t/home/ovh"
printf 'type: tauri\nsource: "~/src"\n' > "$t/ov/tilde.yml"
out=$("${base[@]}" "$S" --config "$t/ov/tilde.yml" 2>/dev/null) || fail "tilde overlay failed"
[[ "$out" == *"-v $t/home/src:/source:ro"* ]] || fail "~ not expanded: $out"
printf 'type: tauri\nsource: %s\n' "$t/home/src" > "$t/home/ovh/h.yml"
out=$("${base[@]}" "$S" --config '~/ovh/h.yml' 2>/dev/null) || fail "~/ overlay path not expanded"
[[ "$out" == *"-v $t/home/ovh:/config:ro"* ]] || fail "~/ overlay path mounted wrongly: $out"
# the overlay's directory must not hold the env file or a secret file (it is mounted into the build container)
mkdir -p "$t/sec/sub" "$t/elsewhere"
printf 'type: tauri\nsource: %s\n' "$t/home/src" > "$t/sec/o.yml"
printf 'x' > "$t/sec/sub/key.p8"; printf '' > "$t/sec/testflight.env"; ln -s "$t/sec/sub/key.p8" "$t/elsewhere/link.p8"
for bad in "ASC_KEY_P8_FILE=$t/sec/sub/key.p8" "XLESS_DIST_KEY_FILE=$t/sec/sub/key.p8" "ASC_ISSUER_ID_FILE=$t/sec/sub/key.p8" \
           "XLESS_TESTFLIGHT_ENV=$t/sec/testflight.env" "ASC_KEY_P8_FILE=$t/elsewhere/link.p8"; do
  code=0; "${base[@]}" "$bad" "$S" --config "$t/sec/o.yml" >/dev/null 2>"$t/err" || code=$?
  [[ $code -eq 2 ]] || fail "secret inside the overlay directory ($bad) exits $code, want 2"
  grep -q "keep the overlay in its own directory" "$t/err" || fail "refusal does not explain ($bad): $(cat "$t/err")"
done
ln -s "$t/sec" "$t/seclink"
code=0; "${base[@]}" ASC_KEY_P8_FILE="$t/sec/sub/key.p8" "$S" --config "$t/seclink/o.yml" >/dev/null 2>&1 || code=$?
[[ $code -eq 2 ]] || fail "overlay directory reached through a symlink not resolved (exit $code)"
"${base[@]}" "$S" --config "$t/ov/my.overlay.yml" >/dev/null 2>&1 || fail "secrets outside the overlay directory refused"
# native mode: the same three steps; step 2 runs without the secret variables
out=$("${base[@]}" XLESS_USE_DOCKER=0 "$S" --config "$t/ov/my.overlay.yml" 2>/dev/null)
[[ "$(sed -n 1p <<<"$out")" == "xless tauri next-build --config $t/ov/my.overlay.yml " ]] || fail "native step 1 wrong: '$out'"
s2=$(sed -n 2p <<<"$out")
[[ "$s2" == "env -u ASC_KEY_ID -u ASC_KEY_ID_FILE "*" -u XLESS_DIST_KEY -u XLESS_DIST_KEY_FILE "*"xless ship --platform ios --config $t/ov/my.overlay.yml --from build --to finalize " ]] || fail "native step 2 wrong: '$s2'"
[[ "$s2" == *"-u ASC_KEY_P8_FILE "* && "$s2" == *"-u ASC_ISSUER_ID_FILE "* ]] || fail "native step 2 keeps secret variables: '$s2'"
[[ "$(sed -n 3p <<<"$out")" == "xless ship --platform ios --config $t/ov/my.overlay.yml --from sign --to upload " ]] || fail "native step 3 wrong: '$out'"
out=$("${base[@]}" XLESS_USE_DOCKER=0 XLESS_SOURCE="$t/proj" "$S" --config "$t/ov/my.overlay.yml" --from upload 2>/dev/null)
[[ "$out" == "xless ship --platform ios --config $t/ov/my.overlay.yml --source $t/proj --from upload --to upload " ]] || fail "native XLESS_SOURCE command wrong: '$out'"
# native, for real (fake xless): step 1's number reaches steps 2 and 3, step 2 sees no secret, a failure stops the run
cat > "$t/bin/xless" <<'X'
#!/bin/sh
echo "$* | ASC_KEY_ID=${ASC_KEY_ID-unset} ASC_KEY_P8_FILE=${ASC_KEY_P8_FILE-unset} BN=${XLESS_BUILD_NUMBER-unset}" >> "$XLOG"
case "$*" in *next-build*) echo "note on stdout first"; echo 1.0.0.2026101503 ;; esac
case "$*" in *"--to finalize"*) exit "${STEP2_EXIT:-0}" ;; esac
exit 0
X
chmod +x "$t/bin/xless"
real=("${base[@]}" XLESS_TESTFLIGHT_DRY_RUN=0 XLESS_USE_DOCKER=0 XLOG="$t/xlog")
: > "$t/xlog"; "${real[@]}" "$S" --config "$t/ov/my.overlay.yml" >/dev/null 2>&1 || fail "native run failed: $(cat "$t/xlog")"
[[ $(wc -l < "$t/xlog") -eq 3 ]] || fail "native run: want 3 invocations: $(cat "$t/xlog")"
grep -q "^tauri next-build .*ASC_KEY_ID=KEYID" "$t/xlog" || fail "step 1 lacks the key: $(cat "$t/xlog")"
grep -q -- "--to finalize | ASC_KEY_ID=unset ASC_KEY_P8_FILE=unset BN=1.0.0.2026101503$" "$t/xlog" || fail "step 2 env wrong: $(cat "$t/xlog")"
grep -q -- "--from sign --to upload | ASC_KEY_ID=KEYID .* BN=1.0.0.2026101503$" "$t/xlog" || fail "step 3 env wrong: $(cat "$t/xlog")"
: > "$t/xlog"; code=0; "${real[@]}" STEP2_EXIT=12 "$S" --config "$t/ov/my.overlay.yml" >/dev/null 2>&1 || code=$?
[[ $code -eq 12 && $(wc -l < "$t/xlog") -eq 2 ]] || fail "step 2 failure: exit $code, $(cat "$t/xlog")"
# usage errors
code=0; "${base[@]}" "$S" --config "$t/ov/none.yml" >/dev/null 2>&1 || code=$?
[[ $code -eq 2 ]] || fail "missing overlay exits $code, want 2"
code=0; "${base[@]}" "$S" --config "$t/ov/my.overlay.yml" "$t/proj" >/dev/null 2>&1 || code=$?
[[ $code -eq 2 ]] || fail "--config with a project dir exits $code, want 2"
code=0; "${base[@]}" "$S" "$t/proj" --config "$t/ov/my.overlay.yml" >/dev/null 2>&1 || code=$?
[[ $code -eq 2 ]] || fail "project dir then --config exits $code, want 2"
printf 'type: tauri\n' > "$t/ov/nosrc.yml"
code=0; "${base[@]}" "$S" --config "$t/ov/nosrc.yml" >/dev/null 2>&1 || code=$?
[[ $code -eq 2 ]] || fail "overlay without source exits $code, want 2"
echo PASS
