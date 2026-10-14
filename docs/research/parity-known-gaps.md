# Parity known gaps (Xcode 27.0 vs xless)

`make parity` (`scripts/parity.sh`) compares an Xcode 27.0 (27A266a) build of `samples/HelloShip` with an xless
build of the same sources. Every Info.plist key, the main binary's LC_BUILD_VERSION and the bundle file lists
match, or differ only in ways that `scripts/parity-allowlist.txt` lists with a reason. Two `Assets.car`
differences remain. Both come from AssetKit (vendored and patched in `ThirdParty/AssetKit`, based on `ASSETKIT_REVISION` in `versions.env`), the third-party CAR writer,
and not from xless. They are accepted for milestone 1. They are allow-listed as `ios:car:` entries.

## 1. No MultiSized Image renditions for the app icon
actool writes a `MultiSized Image` rendition for `AppIcon` for each idiom (phone, pad), next to the 1024px
`Icon Image` renditions. CoreUI and SpringBoard use it to pick an icon size. AssetKit cannot write this rendition
type. To compensate, xless writes the Xcode-named loose fallback PNGs (`AppIcon60x60@2x.png`,
`AppIcon76x76@2x~ipad.png`) and the matching `CFBundleIcons` / `CFBundleIcons~ipad` entries. Nobody has checked
yet whether App Store Connect's icon extraction needs the MultiSized rendition.

## 2. Colorsets lose their scale and are stored in the generic colorspace
actool stores `AccentBlue` at scale 1 in sRGB. AssetKit's `ColorRenderer` writes no scale, and `assetutil --info`
reads AssetKit's color colorspace as `generic` instead of `srgb`. Colors may render slightly differently.

## ITMS-90562 (2026-10-14): not caused by these gaps
The first TestFlight upload failed processing with ITMS-90562 ("not a valid Asset Catalog file"). The cause was
not either gap above but two container defects in upstream AssetKit, now patched in `ThirdParty/AssetKit` (see its
README): the BOM index lacked libBOM's free list, so CoreUI could not open the car for writing (`assetutil`
thinning: "is not a valid AssetCatalog"), and the BITMAPKEYS descriptors did not match the renditions
(`assetutil --validate-file`: "invalid bitmapindex"). `make parity` now runs both checks on the xless car. Both
checks pass without MultiSized Image renditions; actool's own car carries them, but nothing local requires them.

## Follow-up
If App Store Connect reports icon issues or the colors look wrong, patch `ThirdParty/AssetKit`:
- add MultiSized Image renditions for app icons;
- write color renditions at scale 1x with a colorspace that CoreUI reads as sRGB.

Then list the patch in `ThirdParty/AssetKit/README.md`, remove the matching `ios:car:` allow-list entries, and
re-run `make parity`.
