#!/usr/bin/env bash
# Compares an Xcode build of HelloShip with an xless (Linux) build of the same sources. Run on the Mac.
# Checks Info.plist keys, the main binary's LC_BUILD_VERSION, bundle file lists and (iOS) Assets.car renditions,
# validity (assetutil --validate-file) and thinnability;
# legitimate differences are listed with reasons in scripts/parity-allowlist.txt. Known AssetKit Assets.car gaps
# are described in docs/research/parity-known-gaps.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/samples/HelloShip"; W="$ROOT/.xless/parity"; rm -rf "$W"; mkdir -p "$W"
ALLOW="$ROOT/scripts/parity-allowlist.txt"
(cd "$ROOT" && swift build -c release --product xless >/dev/null); X="$(cd "$ROOT" && swift build -c release --show-bin-path)/xless"
status=0

for P in ios macos; do
  if [[ $P == ios ]]; then SCHEME=HelloShip-iOS; DEST='generic/platform=iOS'; else SCHEME=HelloShip-macOS; DEST='generic/platform=macOS'; fi
  (cd "$S" && xcodegen generate -q && xcodebuild -project HelloShipParity.xcodeproj -scheme "$SCHEME" -destination "$DEST" \
     -configuration Release CODE_SIGNING_ALLOWED=NO -derivedDataPath "$W/dd-$P" build -quiet)
  XAPP=$(find "$W/dd-$P/Build/Products" -maxdepth 2 -name HelloShip.app | head -1)
  docker run --rm -v "$S":/work xless:local-arm64 bash -c "for s in build assets finalize; do xless \$s --platform $P || exit 1; done" >/dev/null
  LAPP="$S/.xless/build/$P/final/HelloShip.app"

  "$X" inspect "$XAPP" --platform "$P" > "$W/xcode-$P.json"
  "$X" inspect "$LAPP" --platform "$P" > "$W/xless-$P.json"
  python3 - "$W/xcode-$P.json" "$W/xless-$P.json" "$ALLOW" "$P" "$XAPP" "$LAPP" <<'PY' || status=1
import json, os, sys
a, b, allow_path, plat = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3], sys.argv[4]
allow = {l.split('#')[0].strip() for l in open(allow_path) if l.split('#')[0].strip()}
bad = []
for k in sorted(set(a["infoPlist"]) | set(b["infoPlist"])):
    if f"{plat}:{k}" in allow or f"*:{k}" in allow: continue
    if a["infoPlist"].get(k) != b["infoPlist"].get(k): bad.append(f"Info.plist {k}: xcode={a['infoPlist'].get(k)!r} xless={b['infoPlist'].get(k)!r}")
main = lambda r: next((x for x in r["binaries"] if x["path"].endswith("HelloShip")), None)
if (main(a) or {}).get("buildVersions") != (main(b) or {}).get("buildVersions"):
    bad.append(f"main binary LC_BUILD_VERSION: xcode={main(a)} xless={main(b)}")
files = lambda app: {os.path.relpath(os.path.join(d, f), app) for d, _, fs in os.walk(app) for f in fs}
xf, lf = files(sys.argv[5]), files(sys.argv[6])
for f in sorted(xf ^ lf):
    if f"{plat}:file:{f}" in allow or f"*:file:{f}" in allow: continue
    bad.append(f"bundle file {f}: only in {'xcode' if f in xf else 'xless'}")
print(f"[{plat}] " + ("OK" if not bad else "DIFF\n  " + "\n  ".join(bad)))
sys.exit(1 if bad else 0)
PY

  if [[ $P == ios ]]; then
    # assetutil --info reads cars that App Store processing rejects (ITMS-90562); validate and thin like it does.
    xcrun assetutil --validate-file "$LAPP/Assets.car" >"$W/car-validate.txt" 2>&1 \
      || { echo "[ios] xless Assets.car fails assetutil --validate-file:"; cat "$W/car-validate.txt"; status=1; }
    xcrun assetutil -i phone -s 3 -p srgb -M 4 -g MTL5,1 -r 2026 -o "$W/car-thin.car" "$LAPP/Assets.car" >"$W/car-thin.txt" 2>&1
    [[ -f "$W/car-thin.car" ]] || { echo "[ios] xless Assets.car cannot be thinned:"; cat "$W/car-thin.txt"; status=1; }
    for side in XAPP LAPP; do xcrun assetutil --info "${!side}/Assets.car" | python3 -c '
import json,sys; print("\n".join(sorted({"|".join(str(r.get(k)) for k in ("Name","Idiom","Scale","PixelWidth")) for r in json.load(sys.stdin) if r.get("Name")})))' > "$W/car-$side.txt"; done
    python3 - "$W/car-XAPP.txt" "$W/car-LAPP.txt" "$ALLOW" <<'PY' || status=1
# Rendition lines are Name|Idiom|Scale|PixelWidth; allow-list entries are ios:car:-<line> (only in Xcode's car)
# or ios:car:+<line> (only in xless's car), matched exactly.
import sys
x, l = (set(open(f).read().splitlines()) - {""} for f in sys.argv[1:3])
allow = {e.split('#')[0].strip() for e in open(sys.argv[3]) if e.split('#')[0].strip()}
diffs = sorted([f"-{r}" for r in x - l] + [f"+{r}" for r in l - x], key=lambda d: (d[1:], d[0]))
known = [d for d in diffs if f"ios:car:{d}" in allow]
bad = [d for d in diffs if d not in known]
for d in known: print(f"  known (allow-listed): {d}")
print("[ios] Assets.car renditions " + ("OK" if not bad else "DIFF\n  " + "\n  ".join(bad)))
sys.exit(1 if bad else 0)
PY
  fi
done
exit $status
