#!/usr/bin/env bash
# Records what Apple's actool makes of AssetKit's neutral parity catalog, for AssetKit's parity tests. Mac only.
#
#   scripts/assetkit-golden.sh
#
# Compiles ThirdParty/AssetKit/Tests/AssetKitTests/Fixtures/Parity.xcassets (our own PNGs and colorsets: RGBA with and
# without transparency, RGBA whose alpha is all 255 but one, RGB, gray, gray+alpha, palette; sRGB, display P3, extended
# and linear colors, a dark appearance) with the selected Xcode's actool, reads the car with `xcrun assetutil --info`,
# and writes Fixtures/Parity.expected.<build>.json: every rendition's assetutil fields except digests, sizes and name
# identifiers, sorted. No actool output bytes are committed, only these fields.
# Usage: DEVELOPER_DIR=<Xcode>/Contents/Developer scripts/assetkit-golden.sh
# Any Xcode build is accepted (a build without an XcodeToolsProfile is how a profile is born). The output is
# Fixtures/Parity.expected.<build>.json, the build read from `xcodebuild -version` under DEVELOPER_DIR.
# Env: DEVELOPER_DIR  the Xcode to use. Default: xcode-select's.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname)" == Darwin ]] || { echo "assetkit-golden: needs macOS (uname is $(uname))" >&2; exit 1; }
FOUND="$(xcodebuild -version | sed -n 's/^Build version //p')"
[[ -n "$FOUND" ]] || { echo "assetkit-golden: cannot read the Xcode build from xcodebuild -version" >&2; exit 1; }

FIX="$ROOT/ThirdParty/AssetKit/Tests/AssetKitTests/Fixtures"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/assetkit-golden.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
xcrun actool --output-format human-readable-text --errors --platform iphoneos --minimum-deployment-target 16.0 \
  --target-device iphone --target-device ipad --compile "$TMP" --output-partial-info-plist "$TMP/partial.plist" \
  "$FIX/Parity.xcassets" >"$TMP/actool.log"
VERSION="$(xcrun actool --version --output-format xml1 \
  | /usr/bin/python3 -c 'import plistlib, sys; v = plistlib.loads(sys.stdin.buffer.read())["com.apple.actool.version"]; print(v["short-bundle-version"], "(" + v["bundle-version"] + ")")')"
xcrun assetutil --info "$TMP/Assets.car" > "$TMP/info.json"
/usr/bin/python3 - "$TMP/info.json" "$FIX/Parity.expected.$FOUND.json" "$VERSION" "$FOUND" <<'PY'
import json, sys
info, out, version, build = sys.argv[1:]
skip = {"SHA1Digest", "SizeOnDisk", "NameIdentifier"}
rows = [{k: v for k, v in e.items() if k not in skip} for e in json.load(open(info))[1:]]
rows = [r for r in rows if r.get("AssetType") != "PackedImage"]   # actool's atlas of small images; AssetKit never packs
rows.sort(key=lambda r: (r.get("Name", ""), r.get("Scale", 0), r.get("Appearance", ""), r.get("Idiom", "")))
with open(out, "w") as f:
    json.dump({"actool": version, "xcodeBuild": build, "renditions": rows}, f, indent=2, sort_keys=True)
    f.write("\n")
print(f"wrote {out}: {len(rows)} renditions (actool {version}, Xcode {build})")
PY
