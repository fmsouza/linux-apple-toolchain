# AssetKit (vendored)

A copy of [xtool-org/AssetKit](https://github.com/xtool-org/AssetKit), the `Assets.car` writer that xless's
`assets` stage uses. xless depends on it as a local SwiftPM package (`.package(path: "ThirdParty/AssetKit")`).

- Upstream revision: `e763558b55fcbb5a443b1d7b2c6f0972d8bd14f7` (also `ASSETKIT_REVISION` in `versions.env`).
- Copied: `Sources/`, `Tests/`, `Package.swift`, `LICENSE` (MIT, unchanged). Not copied: `.github/`, `docs/`,
  `Dockerfile`, `.gitignore` and the upstream `README.md`.
- Run its own tests with `swift test --package-path ThirdParty/AssetKit`.

## Patches on top of upstream

1. **BOM free list** (`Sources/AssetKit/BOM/BOMWriter.swift`). The block index now ends with libBOM's free list
   (count 0 and two zeroed pairs) inside `indexLength`, as libBOM writes it. Upstream ended the index right after
   the block table, so libBOM read the vars table count as the free-list count. `assetutil --info` still read the
   car, but CoreUI could not open it for writing: `assetutil` thinning failed with "is not a valid AssetCatalog",
   the same words as the ITMS-90562 rejection App Store processing gave the xless HelloShip build.
2. **BITMAPKEYS descriptors** (`Sources/AssetKit/CAR/BitmapKeys.swift`, `CARWriter.swift`, `RenditionKey.swift`).
   Each descriptor is now computed from the asset's rendition keys: `[1, 0, 4 + 4n, n]` and then, for each of the
   n KEYFORMAT attributes, a bitmask of the values in use. Appearance, identifier, element and part are always
   -1. Every asset gets an entry, colors included. Upstream wrote fixed templates (for example scale 1x/2x/3x and
   phone only for every app icon) and skipped colors, so `assetutil --validate-file` reported "invalid
   bitmapindex". The rule comes from actool 27.0 output and from `assetutil --update-bitmap`.

Tests: `BOMWriterTests` (free list), `BitmapKeysTests` (descriptors), and `AssetutilParseTests` "assetutil
validates and thins the compiled Assets.car" (macOS: `assetutil --validate-file` and thinning).
