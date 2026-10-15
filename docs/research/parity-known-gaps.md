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

## Tauri iOS

`xless tauri compare samples/HelloTauri/reference/reference.json <app>` compares an xless build of
`samples/HelloTauri` with the Mac reference (`tauri ios build` + Xcode 27.0, see docs/research/tauri-ios-contract.md).
Run on the `assets` or `finalize` stage output (`xless build`, `xless assets`, `xless finalize`, all with `--config`),
it reports no `lib:`, `rpath:`, `exe:` or `framework:` line: the executable's 38 linked libraries, platform, minos and
rpath match. `make test-tauri-linux` runs this compare on the `finalize` output and ignores exactly the keys in
`samples/HelloTauri/reference/allowed-gaps.txt`, which is the machine-readable form of this list (the `plist:DT*` keys are
not in it, because they match after `finalize`). These differences remain, each listed with its compare key:

- `plist:DTPlatformName`, `plist:DTPlatformVersion`, `plist:DTSDKName` (`assets` output only): the `finalize` stage
  stamps these, as for every xless build (InfoPlistStamper). After `finalize` they match the reference.
- `plist:ITSAppUsesNonExemptEncryption` (`finalize` output only): `finalize` stamps the overlay's
  `usesNonExemptEncryption`, which App Store uploads need; `tauri ios build` writes no such key.
- Frameworks whose binary is a static archive (for example a CocoaPods xcframework that ships a fat-wrapped `ar` archive) are
  linked but not embedded; rcodesign 0.29.0 cannot sign them (panics in macho_signing.rs); Xcode copies them. The embedded
  copy would never be loaded, since the code is linked into the executable. xless prints `note: <name>.framework is a static
  library; linked, not embedded` during the build.
- `file:PrivacyInfo.xcprivacy`: xless copies the overlay's `privacyManifest` into the bundle, because `finalize`
  requires one for App Store builds; the HelloTauri reference app has none.
- App icon: Tauri's `AppIcon.appiconset` is a multi-size set (one PNG per size and idiom), unlike the single-size
  sets of the m1 samples. App Store Connect rejected AssetKit's per-size output (loose `AppIcon76x76@2x.png` without
  `~ipad`, per-size `CFBundleIcons~ipad` entries) with 90023, "no app icon for iPad of exactly 152x152 pixels". So
  for iOS the `assets` stage compiles every app icon set as Xcode's single-size form: a multi-size set is reduced to
  its 1024×1024 image (the `ios-marketing` one first), and `Assets.car`, the loose `AppIcon60x60@2x.png` /
  `AppIcon76x76@2x~ipad.png` and the `CFBundleIcons` / `CFBundleIcons~ipad` keys are exactly those of the validated
  single-size path. The per-size PNGs are not used: the icons xless ships are renders of the 1024 icon (box-filter
  downscales for the loose files; in `Assets.car`, the 1024 icon itself, scaled by the system). A multi-size set
  without a 1024 image is refused (`[assets] … — fix: add a 1024×1024 ios-marketing icon`); App Store Connect
  requires that icon anyway. The file names and Info.plist keys now match the reference, so the icon has no
  compare keys in `allowed-gaps.txt`. macOS is unchanged (`AppIcon.icns` from every PNG in the set).
- The executable is not stripped. Xcode strips on archive (`STRIP_INSTALLED_PRODUCT`), so the reference's executable
  carries no local symbols, and xless's carries its symbol table. `BundleReport` does not compare sizes or symbols,
  so this does not show up in the compare output. Spike B measured the acceptance app: stripped with `strip`, the
  executable is 34.6 MB, against 34.4 MB for the Mac build.
- Not compared: weak vs. strong linkage. `BundleReport` records install names only. xless's link weak-links 13
  Swift overlays (contract doc, spike A). The empty `assets/` folder reference that both builds ship is also not
  compared, because the report lists files only.
- The increased memory limit capability is portal-only: the App Store Connect API has no capability type for it.
  It must be enabled by hand for the bundle ID in the developer portal; xless refreshes the provisioning profile
  once to pick it up (`Capabilities.map` is empty).
