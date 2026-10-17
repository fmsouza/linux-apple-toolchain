#!/usr/bin/env bash
# Installs and launches an iOS Simulator app (an xless `--destination simulator` build) on this Mac, and checks that
# it is still running some seconds later. Mac only.
#
#   scripts/sim-launch.sh [--seconds N] [--out DIR] [--device NAME] [--keep] <App.app>
#   scripts/sim-launch.sh [...] volume:<docker volume>:<path of the .app, the volume mounted at /cache/work>
#   (or: make sim-launch APP=<App.app | volume:…> [ARGS="--seconds 20"])
#
# volume:…  copies the .app out of a docker volume first: a React Native work volume, with the path xless printed in
#           its container, where the volume is /cache/work (scripts/testflight.sh --destination simulator prints the
#           whole argument). Uses DOCKER_CONTEXT (default colima-xless if it exists) and versions.env's
#           ALPINE_IMAGE (alpine, pinned by digest).
# --device  the simulator to use, created on the newest available iOS runtime when missing (default "xless-sim", an
#           iPhone 17); it is booted, and left booted.
# --seconds how long the app must stay up (default 10).
# --keep    leave the app running afterwards (by default it is terminated once everything is captured, so a system
#           alert it raised does not cover the next app's screenshot).
# --out     where everything goes (default ~/.cache/xless/sim/<app name>): app/<App>.app (the copy), console.log (the
#           app's stdout and stderr), device.log (the simulator's log for the app's process), screenshot.png, and
#           crash/*.ips (crash reports of the app's executable written since the launch, from
#           ~/Library/Logs/DiagnosticReports).
# Exit 0 when the app is running after --seconds, 1 when it is not (the crash report, if any, is named), 2 on a usage
# or setup error. The app's data is the simulator's: the app is reinstalled, not reset (`xcrun simctl uninstall` first
# for a clean start).
set -euo pipefail
die() { echo "sim-launch: $*" >&2; exit 2; }
[[ "$(uname)" == Darwin ]] || die "needs macOS (uname is $(uname))"

seconds=10; out=""; device="xless-sim"; app=""; keep=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --seconds) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || die "--seconds needs a number"; seconds="$2"; shift 2 ;;
    --out) [[ $# -ge 2 ]] || die "--out needs a directory"; out="$2"; shift 2 ;;
    --device) [[ $# -ge 2 ]] || die "--device needs a name"; device="$2"; shift 2 ;;
    --keep) keep=1; shift ;;
    -*) die "unknown option $1" ;;
    *) [[ -z "$app" ]] || die "one app only"; app="$1"; shift ;;
  esac
done
[[ -n "$app" ]] || die "usage: $0 [--seconds N] [--out DIR] [--device NAME] [--keep] <App.app | volume:<volume>:<path>>"

name="$(basename "${app##*:}" .app)"
out="${out:-$HOME/.cache/xless/sim/$name}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"
rm -rf "$out/app" "$out/crash"; mkdir -p "$out/app" "$out/crash"
if [[ "$app" == volume:* ]]; then
  spec="${app#volume:}"; volume="${spec%%:*}"; inner="${spec#*:}"
  [[ -n "$volume" && "$inner" == /*.app ]] || die "volume:<volume>:<absolute path of the .app> expected, got $app"
  ctx="${DOCKER_CONTEXT:-}"
  if [[ -z "$ctx" ]] && docker context ls --format '{{.Name}}' 2>/dev/null | grep -qx 'colima-xless'; then ctx=colima-xless; fi
  docker=(docker); [[ -z "$ctx" ]] || docker+=(--context "$ctx")
  echo "==> copying $inner out of volume $volume" >&2
  alpine="$(sed -n 's/^ALPINE_IMAGE=//p' "$(dirname "$0")/../versions.env")"
  [[ -n "$alpine" ]] || die "versions.env has no ALPINE_IMAGE"
  "${docker[@]}" run --rm -v "$volume:/cache/work:ro" "$alpine" tar -C "$(dirname "$inner")" -cf - "$(basename "$inner")" | tar -C "$out/app" -xf -
else
  [[ -d "$app" ]] || die "$app is not a directory"
  ditto "$app" "$out/app/$name.app"
fi
bundle="$out/app/$name.app"
[[ -f "$bundle/Info.plist" ]] || die "no Info.plist in $bundle"
id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Info.plist")"
exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Info.plist")"
platforms="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms' "$bundle/Info.plist" 2>/dev/null || true)"
[[ "$platforms" == *iPhoneSimulator* ]] || die "$bundle is not a simulator build (CFBundleSupportedPlatforms: $(echo $platforms)); build it with --destination simulator"
codesign --verify --deep --strict "$bundle" 2>"$out/codesign-verify.txt" || die "codesign does not accept the app's signature (see $out/codesign-verify.txt)"

# The simulator: by name, else created on the newest iOS runtime.
udid="$(xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, sys
name = sys.argv[1]
for runtime, devs in json.load(sys.stdin)["devices"].items():
    for d in devs:
        if d["name"] == name and "iOS" in runtime: print(d["udid"]); sys.exit()' "$device")"
if [[ -z "$udid" ]]; then
  runtime="$(xcrun simctl list runtimes available -j | /usr/bin/python3 -c '
import json, sys
rs = [r for r in json.load(sys.stdin)["runtimes"] if r.get("platform") == "iOS" and r.get("isAvailable")]
rs.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
print(rs[-1]["identifier"] if rs else "")')"
  [[ -n "$runtime" ]] || die "no available iOS simulator runtime (install one in Xcode → Settings → Components)"
  udid="$(xcrun simctl create "$device" com.apple.CoreSimulator.SimDeviceType.iPhone-17 "$runtime")"
  echo "==> created simulator $device ($udid) on $runtime" >&2
fi
echo "==> simulator $device ($udid)" >&2
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl terminate "$udid" "$id" >/dev/null 2>&1 || true
xcrun simctl install "$udid" "$bundle"

marker="$out/.launched"; : > "$marker"
# The app's stdout and stderr go to a file the simulator's launchd opens: its path must match the file system's own
# spelling (a case-insensitive file system resolves ~/x/hellorn for ~/x/HelloRN, launchd_sim then fails to spawn the
# app: "No such process"). A fresh temporary directory's physical path does; the log is copied to $out afterwards.
logdir="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$logdir"' EXIT
start="$(date +%s)"
pid="$(xcrun simctl launch --terminate-running-process --stdout="$logdir/console.log" --stderr="$logdir/console.log" "$udid" "$id" | sed -n 's/^[^:]*: *//p')"
[[ "$pid" =~ ^[0-9]+$ ]] || die "simctl launch printed no process ID"
echo "==> launched $id (pid $pid); waiting $seconds s" >&2
sleep "$seconds"
alive=0; ps -p "$pid" >/dev/null 2>&1 && alive=1
cp "$logdir/console.log" "$out/console.log" 2>/dev/null || : > "$out/console.log"
xcrun simctl io "$udid" screenshot "$out/screenshot.png" >/dev/null 2>&1 || true
xcrun simctl spawn "$udid" log show --style compact --start "$(date -r "$start" '+%Y-%m-%d %H:%M:%S')" \
  --predicate "process == \"$exe\"" > "$out/device.log" 2>/dev/null || true
sleep 1   # ReportCrash writes the report shortly after the process dies
find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -name "$exe*" -newer "$marker" -exec cp {} "$out/crash/" \; 2>/dev/null || true
crashes=("$out"/crash/*); [[ -e "${crashes[0]}" ]] || crashes=()
[[ $keep == 1 || $alive == 0 ]] || xcrun simctl terminate "$udid" "$id" >/dev/null 2>&1 || true
if [[ $alive == 1 ]]; then
  echo "==> $name is running after $seconds s (pid $pid); screenshot: $out/screenshot.png" >&2
  exit 0
fi
echo "==> $name is NOT running after $seconds s; console: $out/console.log, log: $out/device.log" >&2
for c in ${crashes[@]+"${crashes[@]}"}; do echo "==> crash report: $c" >&2; done
exit 1
