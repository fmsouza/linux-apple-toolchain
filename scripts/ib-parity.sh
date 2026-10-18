#!/usr/bin/env bash
# Checks the storyboard compiler against ibtool on the Mac (any Xcode: DEVELOPER_DIR=<Xcode>/Contents/Developer). Two checks:
#  1. Golden drift: regenerates every Tests/IBCorpus golden into a temp dir with scripts/ib-golden.sh (same version
#     guards, never --accept-new-ibtool) and diffs it against the committed goldens of the selected Xcode build (Tests/IBCorpus/golden/<build>).
#  2. Rendering: builds a tiny simulator app that shows samples/HelloShipLaunch's LaunchScreen.storyboard as its root
#     view controller, twice with xcodebuild (generic/platform=iOS Simulator, no signing): A keeps ibtool's compiled
#     storyboard, B gets `xless storyboard compile`'s output dropped into the .app. Both run on a dedicated iOS
#     simulator (created here, deleted at exit) and their screenshots must match pixel for pixel (tolerance 0).
# Usage: scripts/ib-parity.sh [--skip-goldens]
set -euo pipefail
die() { echo "ib-parity: $*" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SAMPLE="$ROOT/samples/HelloShipLaunch"; SB="$SAMPLE/Resources/LaunchScreen.storyboard"
DEVICES=(--target-device iphone --target-device ipad); MIN_OS="17.0"   # the sample: TARGETED_DEVICE_FAMILY 1,2, iOS 17.0
BUNDLE_ID="com.example.ibparity"
skip_goldens=0
for a in "$@"; do case "$a" in --skip-goldens) skip_goldens=1 ;; *) die "unknown argument: $a" ;; esac; done
for t in xcodegen jq; do command -v "$t" >/dev/null || die "$t is required"; done

T="$(mktemp -d "${TMPDIR:-/tmp}/ib-parity.XXXXXX")"; DEV=""
cleanup() {
  if [[ -n $DEV ]]; then xcrun simctl shutdown "$DEV" >/dev/null 2>&1 || true; xcrun simctl delete "$DEV" >/dev/null 2>&1 || true; fi
  rm -rf "$T"
}
trap cleanup EXIT

BUILD="$(xcodebuild -version | sed -n 's/^Build version //p')"; [[ -n $BUILD ]] || die "cannot read the Xcode build from xcodebuild -version"

# 1. Golden drift.
if ((skip_goldens)); then
  echo "ib-parity: goldens skipped (--skip-goldens)"
else
  GOLD="$ROOT/Tests/IBCorpus/golden/$BUILD"
  [[ -f $GOLD/IBTOOL_VERSION ]] || die "Tests/IBCorpus/golden/$BUILD/IBTOOL_VERSION is missing (run scripts/ib-golden.sh)"
  IB_GOLDEN_OUT="$T/golden" "$ROOT/scripts/ib-golden.sh" >"$T/golden.log" || { cat "$T/golden.log"; die "ib-golden.sh failed"; }
  diff -r "$GOLD" "$T/golden" >"$T/golden.diff" || { cat "$T/golden.diff"; die "goldens drifted from ibtool (diff above)"; }
  echo "ib-parity: goldens OK ($(grep -c '^ib-golden: ' "$T/golden.log") cases regenerated, no drift)"
fi

# 2. Rendering on the simulator.
# xless is built with the machine's default toolchain, not the Xcode under test (Xcode 26.2's Swift 6.2.3 cannot read this
# package's tools version); the Xcode under test is selected with --xcode-build and used for the two xcodebuild runs.
(cd "$ROOT" && env -u DEVELOPER_DIR swift build --product xless >/dev/null); X="$(cd "$ROOT" && env -u DEVELOPER_DIR swift build --show-bin-path)/xless"
P="$T/app"; mkdir -p "$P/Sources"
cp "$SB" "$P/LaunchScreen.storyboard"; cp -R "$SAMPLE/Resources/Assets.xcassets" "$P/Assets.xcassets"
cat >"$P/Sources/App.swift" <<'SWIFT'
import UIKit

// Shows the launch storyboard as the root view controller, so a screenshot taken after launch shows UIKit's
// rendering of the compiled nibs; records what it loaded so the script can tell a real run from a crash.
@main final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: nil, sessionRole: session.role)
        c.delegateClass = SceneDelegate.self
        return c
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene,
              let vc = UIStoryboard(name: "LaunchScreen", bundle: nil).instantiateInitialViewController() else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = vc
        window.makeKeyAndVisible()
        self.window = window
        let labels = vc.view.subviews.compactMap { ($0 as? UILabel)?.text }
        let images = vc.view.subviews.compactMap { $0 as? UIImageView }.map { $0.image != nil }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? "labels=\(labels) images=\(images)\n".write(to: docs.appendingPathComponent("ib-parity.txt"), atomically: true, encoding: .utf8)
    }
}
SWIFT
cat >"$P/project.yml" <<YAML
name: IBParity
options: { deploymentTarget: { iOS: "$MIN_OS" } }
targets:
  IBParity:
    type: application
    platform: iOS
    sources: [Sources, LaunchScreen.storyboard, Assets.xcassets]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: $BUNDLE_ID
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_UILaunchStoryboardName: LaunchScreen
        INFOPLIST_KEY_UIApplicationSceneManifest_Generation: YES
        TARGETED_DEVICE_FAMILY: "1,2"
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        CODE_SIGNING_ALLOWED: NO
        SWIFT_VERSION: "5.0"
YAML
(cd "$P" && xcodegen generate -q)
build() {   # $1: derived data dir; prints the .app path
  (cd "$P" && xcodebuild -project IBParity.xcodeproj -scheme IBParity -destination 'generic/platform=iOS Simulator' \
     -configuration Debug CODE_SIGNING_ALLOWED=NO -derivedDataPath "$1" build -quiet >"$1.log" 2>&1) \
    || { cat "$1.log"; die "xcodebuild failed"; }
  find "$1/Build/Products" -maxdepth 2 -name IBParity.app | head -1
}
A="$(build "$T/dd-ibtool")"; B="$(build "$T/dd-xless")"
[[ -d $A/LaunchScreen.storyboardc && -d $B/LaunchScreen.storyboardc ]] || die "xcodebuild produced no LaunchScreen.storyboardc"
rm -rf "$B/LaunchScreen.storyboardc"
"$X" storyboard compile "$SB" --xcode-build "$BUILD" --out "$B/LaunchScreen.storyboardc" "${DEVICES[@]}" --minimum-deployment-target "$MIN_OS"
if diff -r "$A/LaunchScreen.storyboardc" "$B/LaunchScreen.storyboardc" >"$T/storyboardc.diff"; then
  echo "ib-parity: xless LaunchScreen.storyboardc is byte-identical to Xcode's"
else
  cat "$T/storyboardc.diff"; die "xless LaunchScreen.storyboardc differs from Xcode's"
fi

# Dedicated simulator on the newest simulator runtime whose iOS major matches this Xcode's iphonesimulator SDK
# (17C52 -> any iOS 26.x, 27A266a -> any iOS 27.x).
SDKVER="$(xcrun --sdk iphonesimulator --show-sdk-version)"; MAJOR="${SDKVER%%.*}"
[[ $MAJOR =~ ^[0-9]+$ ]] || die "cannot read the iphonesimulator SDK version (got '$SDKVER')"
RUNTIME="$(xcrun simctl list runtimes -j | jq -r --arg m "$MAJOR" '[.runtimes[] | select(.isAvailable and (.identifier | test("SimRuntime\\.iOS-" + $m + "-")))] | sort_by(.version | split(".") | map(tonumber)) | last | .identifier // empty')"
[[ -n $RUNTIME ]] || die "Xcode $BUILD (iphonesimulator SDK $SDKVER) needs an installed iOS $MAJOR.x simulator runtime, and none is available (install one in Xcode → Settings → Components)"
DEVTYPE="$(xcrun simctl list runtimes -j | jq -r --arg r "$RUNTIME" '.runtimes[] | select(.identifier == $r) | .supportedDeviceTypes | map(select(.productFamily == "iPhone")) | first | .identifier // empty')"
[[ -n $DEVTYPE ]] || die "runtime $RUNTIME supports no iPhone device type"
DEV="$(xcrun simctl create "xless-ib-parity-$$" "$DEVTYPE" "$RUNTIME")"
xcrun simctl boot "$DEV"; xcrun simctl bootstatus "$DEV" -b >/dev/null
sleep 20   # a fresh simulator posts system banners (e.g. iOS 26.3's "Ready for Apple Intelligence") that would sit over the first screenshot; let them expire
xcrun simctl ui "$DEV" appearance light
xcrun simctl status_bar "$DEV" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --operatorName "" --batteryState charged --batteryLevel 100
echo "ib-parity: simulator $(basename "$DEVTYPE") on $(basename "$RUNTIME") ($DEV)"

shoot() {   # $1: .app, $2: screenshot path
  xcrun simctl install "$DEV" "$1"
  xcrun simctl launch "$DEV" "$BUNDLE_ID" >/dev/null
  sleep 2
  xcrun simctl io "$DEV" screenshot "$2" >/dev/null 2>&1
  local marker; marker="$(xcrun simctl get_app_container "$DEV" "$BUNDLE_ID" data)/Documents/ib-parity.txt"
  [[ -f $marker ]] || die "$(basename "$2" .png): the app did not load the storyboard (no $marker)"
  grep -qF 'labels=["Built on Linux"] images=[true]' "$marker" || die "$(basename "$2" .png): unexpected storyboard contents: $(cat "$marker")"
  xcrun simctl terminate "$DEV" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$DEV" "$BUNDLE_ID"
}
shoot "$A" "$T/ibtool.png"
shoot "$B" "$T/xless.png"

cat >"$T/pixeldiff.swift" <<'SWIFT'
// Usage: pixeldiff a.png b.png — exits 0 when both decode to the same size and identical RGBA8 sRGB pixels.
import CoreGraphics
import Foundation
import ImageIO

func pixels(_ path: String) -> (Int, Int, [UInt8]) {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("cannot decode \(path)") }
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, buf)
}
let (aw, ah, a) = pixels(CommandLine.arguments[1]), (bw, bh, b) = pixels(CommandLine.arguments[2])
guard aw == bw, ah == bh else { print("size differs: \(aw)x\(ah) vs \(bw)x\(bh)"); exit(1) }
let differing = stride(from: 0, to: a.count, by: 4).filter { a[$0..<$0 + 4] != b[$0..<$0 + 4] }.count
print("\(aw)x\(ah), \(differing) differing pixels")
exit(differing == 0 ? 0 : 1)
SWIFT
if out="$(swift "$T/pixeldiff.swift" "$T/ibtool.png" "$T/xless.png")"; then
  echo "ib-parity: screenshots identical ($out)"
else
  mkdir -p "$ROOT/.xless/ib-parity"; cp "$T/ibtool.png" "$T/xless.png" "$ROOT/.xless/ib-parity/"
  die "screenshots differ: $out (kept in .xless/ib-parity/)"
fi
echo "ib-parity: OK"
