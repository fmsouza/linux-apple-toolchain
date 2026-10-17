#!/usr/bin/env bash
# Mac reference build of an Expo (CNG) React Native app with Expo's CLI, CocoaPods and Xcode. Mac only.
#
#   scripts/rn-reference.sh <expo-app-root> <out-dir>
#   (or: make rn-reference [APP=samples/HelloRN] [OUT=samples/HelloRN/reference])
#
# Steps, all in a work copy: `pnpm install --frozen-lockfile` (corepack), `expo prebuild --platform ios --no-install`,
# `bundle install` + `bundle exec pod install` in ios/, then
# `xcodebuild -workspace … -scheme … -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO build`.
# The scheme is the workspace's own (Expo names project, scheme and app target after the app's display name).
#
# Env: REF_WORK                 reuse this scratch dir instead of a fresh mktemp one (the work copy is recreated each
#                               run; derived data and the Bundler path are kept, so rebuilds are incremental)
#      DEVELOPER_DIR            the Xcode to use. Default: ~/.cache/xless/Xcode.app/Contents/Developer when that is
#                               versions.env's XCODE_BUILD, else xcode-select's. Any other build is refused.
#      REF_ALLOW_XCODE_BUILD    escape hatch for experiments only: accept this other Xcode build (it is recorded in
#                               the outputs, which then must not be committed as the reference)
#
# The source tree is never touched: its tracked files, plus untracked files that are not ignored (so an uncommitted
# sample can be referenced), are copied into <tmp>/work and everything runs there. Gems go to <tmp>/bundle.
#
# Outputs in <out> (all normalised: the work copy is $APP, derived data $DERIVED, the SDK $SDK, Xcode's developer dir
# $DEVELOPER, the scratch dir $REFTMP, the home directory $HOME):
#   reference.json      `xless tauri report` of the unsigned .app (its file list includes PlugIns/, but not the
#                       extension's executable or Info.plist)
#   reference-appex.json  the same report for each PlugIns/*.appex, keyed by bundle name
#   build-settings.json selected `xcodebuild -showBuildSettings -json` keys for each native target of the app project
#   pif-summary.json    from `xcodebuild -dumpPIF`: the app project's targets (name, product type, product, explicit
#                       dependencies, build phases by type and name) and the workspace's project list; not the dump
# xcodebuild's output goes to <tmp>/build.log. The work copy is left in place.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/versions.env"

[[ $# -eq 2 ]] || { echo "usage: $0 <expo-app-root> <out-dir>" >&2; exit 2; }
[[ "$(uname)" == Darwin ]] || { echo "rn-reference: needs macOS (uname is $(uname))" >&2; exit 1; }
# The pinned Xcode: DEVELOPER_DIR if set, else the APFS clone at ~/.cache/xless/Xcode.app when it is the pinned build
# (an /Applications Xcode may have auto-updated), else xcode-select's.
CLONE="$HOME/.cache/xless/Xcode.app/Contents/Developer"
if [[ -z "${DEVELOPER_DIR:-}" && -d "$CLONE" ]] \
   && DEVELOPER_DIR="$CLONE" xcodebuild -version 2>/dev/null | grep -qx "Build version $XCODE_BUILD"; then
  export DEVELOPER_DIR="$CLONE"
fi
XCODE_FOUND="$(xcodebuild -version | sed -n 's/^Build version //p')"
if [[ "$XCODE_FOUND" != "$XCODE_BUILD" ]]; then
  if [[ -n "$XCODE_FOUND" && "$XCODE_FOUND" == "${REF_ALLOW_XCODE_BUILD:-}" ]]; then
    echo "rn-reference: WARNING: Xcode build $XCODE_FOUND, not $XCODE_BUILD (accepted by REF_ALLOW_XCODE_BUILD;" \
         "the outputs are not a valid reference for the pinned SDK)" >&2
  else
    echo "rn-reference: needs Xcode build $XCODE_BUILD (set DEVELOPER_DIR, or put it at $CLONE);" \
         "found: $(xcodebuild -version | tr '\n' ' ')" >&2
    exit 1
  fi
fi
echo "==> Xcode $XCODE_FOUND at ${DEVELOPER_DIR:-$(xcode-select -p)}"

APP="$(cd "$1" && pwd)"
mkdir -p "$2"; OUT="$(cd "$2" && pwd)"
git -C "$APP" rev-parse --git-dir >/dev/null 2>&1 || { echo "rn-reference: $APP is not in a git repository" >&2; exit 1; }

if [[ -n "${REF_WORK:-}" ]]; then TMP="$REF_WORK"; mkdir -p "$TMP"; else TMP="$(mktemp -d "${TMPDIR:-/tmp}/rn-ref.XXXXXX")"; fi
TMP_LOGICAL="$(cd "$TMP" && pwd -L)"; TMP="$(cd "$TMP" && pwd -P)"   # /var/folders/… vs /private/var/folders/…
WORK="$TMP/work"; DD="$TMP/dd"
rm -rf "$WORK"; mkdir -p "$WORK"
echo "==> work copy: $WORK"
git -C "$APP" ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' f; do
  if [[ -e "$APP/$f" || -L "$APP/$f" ]]; then printf '%s\0' "$f"; fi
done | rsync -a --from0 --files-from=- "$APP"/ "$WORK"/
# Clear old outputs only after the sync: <out> may sit inside the app tree (samples/HelloRN/reference).
rm -f "$OUT"/{reference.json,reference-appex.json,build-settings.json,pif-summary.json}
# The reference dir is not an input of the build.
if [[ "$OUT" == "$APP/"* ]]; then rm -rf "${WORK:?}/${OUT#"$APP"/}"; fi

# Build-setting-named variables in the environment override the project under CocoaPods (xcodeproj gem); keep the
# environment clean of the ones a shell may carry. Telemetry and prompts off.
unset SWIFT_VERSION SDKROOT IPHONEOS_DEPLOYMENT_TARGET DEVELOPMENT_TEAM
export EXPO_NO_TELEMETRY=1 COREPACK_ENABLE_DOWNLOAD_PROMPT=0 CI=1 LANG="${LANG:-en_US.UTF-8}"
export BUNDLE_PATH="$TMP/bundle"

cd "$WORK"
corepack pnpm install --frozen-lockfile
corepack pnpm exec expo prebuild --platform ios --no-install
cd ios
bundle install
bundle exec pod install

WORKSPACE="$(ls -d "$WORK"/ios/*.xcworkspace | head -1)"
PROJECT="${WORKSPACE%.xcworkspace}.xcodeproj"
SCHEME="$(basename "$WORKSPACE" .xcworkspace)"
echo "==> workspace: $WORKSPACE, scheme: $SCHEME"
XB=(xcodebuild -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration Release -sdk iphoneos
    -destination 'generic/platform=iOS' -derivedDataPath "$DD")
set +e
"${XB[@]}" CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "$TMP/build.log"
status=${PIPESTATUS[0]}
set -e
[[ $status -eq 0 ]] || { echo "rn-reference: xcodebuild exited $status (see $TMP/build.log)" >&2; exit "$status"; }
APP_BUNDLE="$DD/Build/Products/Release-iphoneos/$SCHEME.app"
[[ -d "$APP_BUNDLE" ]] || { echo "rn-reference: no $APP_BUNDLE" >&2; exit 1; }
echo "==> app: $APP_BUNDLE"

# --- bundle reports ---------------------------------------------------------------------------------------------
(cd "$ROOT" && env -u DEVELOPER_DIR swift build --product xless -q)
XLESS="$(cd "$ROOT" && env -u DEVELOPER_DIR swift build --show-bin-path)/xless"
"$XLESS" tauri report "$APP_BUNDLE" --json "$OUT/reference.json"
APPEX_REPORTS=()
for appex in "$APP_BUNDLE"/PlugIns/*.appex; do
  [[ -d "$appex" ]] || continue
  "$XLESS" tauri report "$appex" --json "$TMP/$(basename "$appex").json"
  APPEX_REPORTS+=("$(basename "$appex")" "$TMP/$(basename "$appex").json")
done

# --- build settings and PIF -------------------------------------------------------------------------------------
# One -showBuildSettings per native target of the app project, read through the workspace (so the CocoaPods base
# xcconfigs and derived-data paths are those of the build above).
TARGETS="$(xcodebuild -project "$PROJECT" -list -json | /usr/bin/python3 -c 'import json, sys; print("\n".join(json.load(sys.stdin)["project"]["targets"]))')"
SETTINGS=()
while IFS= read -r t; do
  [[ -n "$t" ]] || continue
  xcodebuild -project "$PROJECT" -target "$t" -configuration Release -sdk iphoneos -showBuildSettings -json \
    SYMROOT="$DD/Build/Products" OBJROOT="$DD/Build/Intermediates.noindex" > "$TMP/settings-$t.json"
  SETTINGS+=("$t" "$TMP/settings-$t.json")
done <<< "$TARGETS"
"${XB[@]}" -dumpPIF "$TMP/workspace.pif" >/dev/null

DEV="${DEVELOPER_DIR:-$(xcode-select -p)}"
SDK="$(/usr/bin/xcrun --sdk iphoneos --show-sdk-path)"
/usr/bin/python3 "$ROOT/scripts/rn-reference-summary.py" \
  --out "$OUT" --xcode "$XCODE_FOUND" --project "$PROJECT" --pif "$TMP/workspace.pif" \
  --prefix '$APP' "$WORK" --prefix '$APP' "$TMP_LOGICAL/work" --prefix '$DERIVED' "$DD" \
  --prefix '$DERIVED' "$TMP_LOGICAL/dd" --prefix '$REFTMP' "$TMP" --prefix '$REFTMP' "$TMP_LOGICAL" \
  --prefix '$APP' "${WORK#/private}" --prefix '$DERIVED' "${DD#/private}" --prefix '$REFTMP' "${TMP#/private}" \
  --prefix '$SDK' "$SDK" --prefix '$DEVELOPER' "$DEV" --prefix '$HOME' "$HOME" \
  --settings "${SETTINGS[@]}" --appex ${APPEX_REPORTS[@]+"${APPEX_REPORTS[@]}"}
echo "==> wrote $OUT/{reference.json,reference-appex.json,build-settings.json,pif-summary.json}"
