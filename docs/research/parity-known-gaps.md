# Parity known gaps (Xcode 27.0 vs xless)

`make parity` (`scripts/parity.sh`) compares an Xcode 27.0 (27A266a) build of `samples/HelloShip` with an xless
build of the same sources. Every Info.plist key, the main binary's LC_BUILD_VERSION and the bundle file lists
match, or differ only in ways that `scripts/parity-allowlist.txt` lists with a reason. `Assets.car` is compared
rendition by rendition with `xless tauri compare --assets-only` (see "Asset catalog comparison" below). One
difference remains. It comes from AssetKit (vendored and patched in `ThirdParty/AssetKit`, based on
`ASSETKIT_REVISION` in `versions.env`), the third-party CAR writer, and not from xless. It is accepted for milestone 1
and allow-listed as `ios:car:` entries.

## 1. No MultiSized Image renditions for the app icon
actool writes a `MultiSized Image` rendition for `AppIcon` for each idiom (phone, pad), next to the 1024px
`Icon Image` renditions. CoreUI and SpringBoard use it to pick an icon size. AssetKit cannot write this rendition
type. To compensate, xless writes the Xcode-named loose fallback PNGs (`AppIcon60x60@2x.png`,
`AppIcon76x76@2x~ipad.png`) and the matching `CFBundleIcons` / `CFBundleIcons~ipad` entries. Nobody has checked
yet whether App Store Connect's icon extraction needs the MultiSized rendition.

## 2. Fixed (2026-10-17): colorsets and transparent images
Two AssetKit defects changed how assets draw, and are now patched (`ThirdParty/AssetKit/README.md`, patches 3 and 4):

- **Transparent PNGs drew on a black square.** The word after `MLEC` in a bitmap body is a flags word whose bit 1
  (0x2) marks the rendition opaque; AssetKit wrote 3 for every bitmap, so `assetutil --info` said `Opaque: True` and
  CoreUI dropped the alpha. Seen on a device as an Expo splash logo on a black square. actool 27.0, measured on neutral
  PNGs: a rendition is opaque iff every pixel's alpha is 255, whatever the PNG colour type (RGBA with all alpha 255:
  opaque; one alpha of 254: not; RGB, gray, palette: opaque). Its deepmap2 bodies carry 2 or 0, its LZFSE (KCBC) app
  icons 3 or 1; AssetKit now writes 3 or 1. Pixels were already right: premultiplied `round(c * a / 255)`, as actool
  stores them, and drawn through UIKit the fixed car is pixel-identical to actool's for that logo.
- **Colors were unreadable.** `assetutil` read AssetKit's colors as one component (2e-323) in a "generic" space with
  no scale, and `UIColor(named:)` returned nil. They are now written as actool writes them (scale 1, element 85,
  part 217, `COLR` tag and version 1, actool's colour space IDs).

`AccentBlue` (HelloShip) now matches actool's: scale 1, sRGB, the same components.

## 3. Smaller differences that do not change how assets draw
- Images are stored LZFSE-compressed (assetutil `Compression: lzfse`); actool 27.0 uses deepmap2 for imagesets and LZFSE
  for app icons. CoreUI decodes both. deepmap2 is not exactly lossless: on neutral gradients actool's pixels differ
  from the PNG by 1 in a quarter of the pixels, AssetKit's are exact.
- Grayscale PNGs (gray, gray+alpha, and an RGBA PNG whose pixels are all clear): actool stores 8-bit gray
  (`Encoding: Gray`, "gray gamma 22"), AssetKit ARGB in sRGB. The pixels drawn through UIKit are the same.
- actool packs small images into `ZZZZPackedAsset` atlases; AssetKit writes each image on its own. The comparison
  ignores `PackedImage` renditions.
- Colors with a `display-gamut` (P3 variants of one color) get a display-gamut key attribute from actool; AssetKit's
  key format has none, so both variants share one key. `gray-gamma-22` colors (a `white` component) are not parsed.

## Asset catalog comparison
`xless tauri report` records, on a Mac, what `xcrun assetutil --info` says about every `.car` in the bundle
(`assetCatalogs`), reduced to the fields that change how a rendition draws: AssetType, Name, Idiom, Scale,
Appearance, DisplayGamut, Opaque, Encoding, ColorModel, Colorspace, BitsPerComponent, pixel size, Template Mode, color
components, Icon Index and Sizes (not Compression, SizeOnDisk, digests or names). `xless tauri compare` compares them
when both reports have them, with keys `car:<car>:<Name>/<Idiom>/<Scale>/<Appearance>/<AssetType>`; on Linux
(no assetutil) it compares the rest and says so. `xless tauri compare --assets-only <reference> <dir>` compares only
the catalogs of a directory holding a bundle's `.car` files, which is how `scripts/test-rn-linux.sh` checks the Linux
build from the Mac host. `make parity` (HelloShip) uses the same comparison.

## ITMS-90562 (2026-10-14): not caused by these gaps
The first TestFlight upload failed processing with ITMS-90562 ("not a valid Asset Catalog file"). The cause was
not either gap above but two container defects in upstream AssetKit, now patched in `ThirdParty/AssetKit` (see its
README): the BOM index lacked libBOM's free list, so CoreUI could not open the car for writing (`assetutil`
thinning: "is not a valid AssetCatalog"), and the BITMAPKEYS descriptors did not match the renditions
(`assetutil --validate-file`: "invalid bitmapindex"). `make parity` now runs both checks on the xless car. Both
checks pass without MultiSized Image renditions; actool's own car carries them, but nothing local requires them.

## Follow-up
If App Store Connect reports icon issues, patch `ThirdParty/AssetKit` to add MultiSized Image renditions for app icons.

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
  requires that icon anyway. The file names and Info.plist keys now match the reference. `Assets.car` itself differs:
  the reference has an Icon Image per size and MultiSized Image renditions, xless's car the single-size form; those
  `car:` keys (compared on a Mac host only, "Asset catalog comparison" above) are in `allowed-gaps.txt`. macOS is
  unchanged (`AppIcon.icns` from every PNG in the set; the macOS app has no `Assets.car`, so nothing is compared).
- The executable is not stripped. Xcode strips on archive (`STRIP_INSTALLED_PRODUCT`), so the reference's executable
  carries no local symbols, and xless's carries its symbol table. `BundleReport` does not compare sizes or symbols,
  so this does not show up in the compare output. Spike B measured the acceptance app: stripped with `strip`, the
  executable is 34.6 MB, against 34.4 MB for the Mac build.
- `bundle.resources` and `bundle.fileAssociations` (HelloTauri's desktop config, milestone 2c): `tauri ios build`
  applies both to the iOS app too, and so does xless. The resources are staged into `gen/apple/assets/` with Tauri's
  path mapping (shipped through the `assets` folder reference: `assets/resources/hello.txt`), and the associations
  become `CFBundleDocumentTypes` in the Info.plist, with the code the macOS bundler uses. No compare keys remain for them.
- Not compared: weak vs. strong linkage. `BundleReport` records install names only. xless's link weak-links 13
  Swift overlays (contract doc, spike A). The `assets/` folder itself is also not compared, because the report lists
  files only.
- The increased memory limit capability is portal-only: the App Store Connect API has no capability type for it.
  It must be enabled by hand for the bundle ID in the developer portal; xless refreshes the provisioning profile
  once to pick it up (`Capabilities.map` is empty).

## Tauri macOS

`xless tauri compare samples/HelloTauri/reference/macos/reference.json <app>` compares an xless build of
`samples/HelloTauri` for macOS (`xless ship --config … --platform macos --to finalize`, universal, unsigned) with the
Mac reference (`tauri build --target universal-apple-darwin --no-sign`, see docs/research/tauri-ios-contract.md,
"macOS (desktop)"). It reports no `lib:`, `rpath:`, `exe:` or `framework:` line: both slices (`x86_64`, `arm64`) have
the reference's 14 linked libraries (no CFNetwork, thanks to the linker wrapper's `-Wl,-framework,Foundation`),
platform macOS, minos 11.0 and no rpath. The files and the Info.plist values tauri-bundler writes match.
`samples/HelloTauri/reference/macos/allowed-gaps.txt` is the machine-readable form of this list:

- `plist:DTPlatformName`, `plist:DTPlatformVersion`, `plist:DTSDKName`, `plist:CFBundleSupportedPlatforms`: `finalize`
  stamps these (InfoPlistStamper), as for every xless build; tauri-bundler does not run Xcode and writes none. The
  other stamped keys (`DTXcode`, `DTSDKBuild`, …, `CFBundleVersion`) are volatile and not compared.
- `file:Contents/PkgInfo`: `finalize` writes `APPL????`, as Xcode does; tauri-bundler writes no PkgInfo.
- `plist:ITSAppUsesNonExemptEncryption`: `finalize` stamps the overlay's `usesNonExemptEncryption`.
- Not compared: Info.plist key order. tauri-bundler writes its keys in a fixed order (contract doc); xless writes the
  same keys and values, serialized by Foundation (finalize rewrites the file as a binary plist).
- `LSItemContentTypes` order: tauri-utils collects the UTIs in a HashSet, so their order changes from one Tauri build
  to the next. xless writes them in a fixed order: explicit `contentTypes`, then the UTIs of the extensions, then the
  one of `mimeType`. HelloTauri has none; for an app whose associations infer several UTIs, the compare can show a
  `plist:CFBundleDocumentTypes` difference that is order only.
- Per-target `bundle.resources` (ruling R4): when a resource differs between the two target builds and each copy is a
  thin Mach-O of its own architecture, xless merges the copies into one universal file; Tauri ships the copy of the
  last build (x86_64), unsigned. Any other per-target difference is a `[build]` error. Every loose Mach-O in the
  bundle (such a resource, a `.dylib` from `bundle.macOS.frameworks`, an embedded framework's binary) is signed with the
  hardened runtime: rcodesign signs them, but applies an unscoped `--code-signature-flags runtime` to the main executable
  only, so the sign stage adds a `--code-signature-flags <path>:runtime` for each Mach-O by its real path (a
  framework-level scope does not reach `Versions/A/<binary>`). HelloTauri has no such file.
- Not compared: symbols and sizes. xless turns cargo's strip off and has the linker drop local symbols (`-Wl,-x`),
  the only stripping macOS 27's dyld accepts for both slices (contract doc, "macOS — spike B").

DMG (`xless ship --config … --platform macos`, `package` stage; checked unsigned by `scripts/test-tauri-linux.sh --platform macos`
against `samples/HelloTauri/reference/macos/dmg.json`):

- Default layout: the image holds the app and an `/Applications` symlink on an HFS+ volume. tauri-bundler's create-dmg
  also sets a window size, icon positions, a hidden extension and a custom volume icon (`.VolumeIcon.icns`) through
  Finder, which does not exist on Linux. The script's listing check ignores `.VolumeIcon.icns` for that reason.
- The image is built without `hdiutil`: an HFS+ volume (`mkfs.hfsplus`, libdmg-hfsplus `hfsplus`) compressed by `dmg` (zlib).
  It is not byte-identical to an `hdiutil convert -format UDZO` image; it mounts and has the same contents.
- Updater artefacts (`.app.tar.gz` and its signature) and bundle targets other than `app` and `dmg` are out of scope.
- Frameworks and libraries whose binary is a static archive are linked into the executable, not embedded (as on iOS).
