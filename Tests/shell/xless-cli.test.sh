#!/usr/bin/env bash
# The CLI's refusals for `--destination simulator`, run against the built xless (no docker, no network, no secrets): every
# stage after build exits with its own code and `[stage]` prefix before it reads anything (sign and upload never reach App
# Store Connect: fake credentials are set and must not matter), `ship` refuses a range past build as a usage error, and the
# simulator is refused for a Tauri overlay and for xless.yml. The policy itself is unit-tested in
# Tests/XlessCoreTests/StagePolicyTests.swift; this checks that each command asks it.
#   Tests/shell/xless-cli.test.sh            (builds xless with `swift build`; XLESS_BIN=<path> uses that binary)
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
x="${XLESS_BIN:-}"
if [[ -z "$x" ]]; then
  (cd "$repo" && env -u DEVELOPER_DIR swift build --product xless -q)
  x="$(cd "$repo" && env -u DEVELOPER_DIR swift build --show-bin-path)/xless"
fi
mkdir -p "$t/home" "$t/work"
base=(env -i HOME="$t/home" PATH=/usr/bin:/bin XLESS_WORK_ROOT="$t/work" XLESS_BUILD_NUMBER=1.0.0.2026101601
      ASC_KEY_ID=FAKE ASC_ISSUER_ID=FAKE ASC_KEY_P8_FILE="$t/none.p8" XLESS_DIST_KEY_FILE="$t/none.pem")
rn=(--config "$repo/samples/HelloRN/xless.overlay.yml" --source "$repo/samples/HelloRN" --platform ios)

expect() {   # CODE PREFIX COMMAND...: exit code and the start of the error line
  local want="$1" prefix="$2" code=0; shift 2
  "${base[@]}" "$x" "$@" >/dev/null 2>"$t/err" || code=$?
  [[ $code -eq $want ]] || fail "xless $* exits $code, want $want: $(cat "$t/err")"
  [[ "$(head -1 "$t/err")" == "$prefix"* ]] || fail "xless $* says: $(head -1 "$t/err"), want $prefix…"
}

# Each stage after build: its own exit code, refused as the stage's first step.
expect 13 "error: [assets] --destination simulator builds stop at build" assets "${rn[@]}" --destination simulator
expect 14 "error: [finalize] --destination simulator builds stop at build" finalize "${rn[@]}" --destination simulator
expect 15 "error: [sign] --destination simulator builds stop at build" sign "${rn[@]}" --destination simulator
expect 16 "error: [package] --destination simulator builds stop at build" package "${rn[@]}" --destination simulator
expect 17 "error: [upload] --destination simulator builds stop at build" upload "${rn[@]}" --destination simulator
grep -q "ios-simulator/app/<App>.app" "$t/err" || fail "the refusal does not name the simulator app: $(cat "$t/err")"
# ship: past build is a usage error (ArgumentParser's 64), before anything runs.
for to in assets finalize sign package upload; do
  expect 64 "Error: --to $to: --destination simulator builds stop at build" ship "${rn[@]}" --destination simulator --to "$to"
done
expect 64 "Error: --to build comes before --from sign" ship "${rn[@]}" --destination simulator --from sign
# Nothing was built or signed: only the build number record exists in the work copy.
[[ -z "$(find "$t/work" -type f ! -name build-number)" ]] || fail "files written: $(find "$t/work" -type f)"
# The simulator is for React Native overlays only.
printf 'type: tauri\nsource: .\n' > "$t/tauri.yml"
expect 10 "error: [config] --destination simulator builds React Native overlays only" build --config "$t/tauri.yml" --platform ios --destination simulator
expect 10 "error: [config] --destination simulator builds React Native overlays only" ship --project "$repo/samples/HelloShip" --platform ios --destination simulator
echo PASS
