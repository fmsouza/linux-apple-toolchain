# xless.yml reference

`xless.yml` lives in the project directory next to `Package.swift`. Example (the HelloShip sample):

```yaml
bundleID: app.example.helloship
teamID: ABCDE12345
version: 1.0.0
build: 1
platforms:
  ios:   { minimumOS: "17.0", product: HelloShip, entitlements: ios.entitlements }
  macos: { minimumOS: "14.0", product: HelloShip, entitlements: macos.entitlements, distribution: developer-id }
assets: Resources/Assets.xcassets
privacyManifest: Resources/PrivacyInfo.xcprivacy
infoPlist: Resources/Info.plist
```

## Top-level keys

| Key | Type | Required | Notes |
|---|---|---|---|
| `bundleID` | string | yes | Reverse-DNS, e.g. `com.example.app`: dot-separated segments of letters, digits and `-`, at least two segments. |
| `teamID` | string | yes | Exactly 10 characters, `A-Z` and `0-9`. From developer.apple.com → Membership. `sign` fails if it differs from the team of the App Store Connect key (read from the provisioning profile). |
| `version` | string | yes | Marketing version (`CFBundleShortVersionString`): 1 to 3 dot-separated integers. Quote it if YAML would read it as a number. |
| `build` | string or integer | yes | Build number (`CFBundleVersion`): 1 to 3 dot-separated integers. Overridden by `--build-number` or `XLESS_BUILD_NUMBER`. Each upload of a given `version` needs a higher one than every earlier upload, from any machine (see [README.md](README.md#secrets)). |
| `platforms` | map | yes | At least one of `ios`, `macos`. Any other key is an error. |
| `assets` | path | required for iOS (app-store) | Asset catalog (`.xcassets`), relative to the project. Compiled to `Assets.car` on iOS and to an `.icns` icon on macOS (macOS has no `Assets.car`). App Store builds fail at `assets` unless it contains an `.appiconset`. |
| `privacyManifest` | path | required for iOS (app-store) | `PrivacyInfo.xcprivacy`, copied into the bundle; `finalize` fails for App Store builds if it is missing. |
| `infoPlist` | path | no | Extra Info.plist keys merged into the generated one (usage descriptions, orientations, export-compliance keys). |

## `platforms.<ios|macos>` keys

| Key | Type | Required | Notes |
|---|---|---|---|
| `minimumOS` | string | yes | Dotted version such as `"17.0"`. For iOS it must be 13.0 or later (Apple's rule, checked at `finalize`). Keep it equal to the `platforms:` in `Package.swift`. |
| `product` | string | yes | The library product in `Package.swift` that holds the app (e.g. `.library(name: "HelloShip", targets: ["HelloShip"])`). xtool (iOS) and xless (macOS) link it into a generated executable named after it. |
| `entitlements` | path | no | Entitlements plist, relative to the project. Managed and security-sensitive entitlements are gated against the provisioning profile. |
| `distribution` | `app-store` or `developer-id` | no | Defaults: iOS `app-store`, macOS `developer-id`. |
| `bundleID` | string | no | Overrides the top-level `bundleID` for this platform. Same format rule. |

## Validation rules

- `distribution` is fixed in milestone 1. iOS must be `app-store`; macOS must be `developer-id` (Mac App Store is not supported, see [research/mas-pkg.md](research/mas-pkg.md)). Anything else is a config error.
- `platforms.<p>.minimumOS` must parse as a dotted version.
- Invalid configs fail in the config stage (exit code 10) with `[config] cause — fix`.

## Environment

| Variable | Effect |
|---|---|
| `XLESS_BUILD_NUMBER` | Overrides `build`. `--build-number` takes precedence. |
| `XLESS_TOOLCHAIN_META` | Path of `toolchain-meta.json`. Default: `/opt/xless/toolchain-meta.json` if present, else `$XDG_CONFIG_HOME/xless/toolchain-meta.json` (`~/.config/xless/toolchain-meta.json` when `XDG_CONFIG_HOME` is unset). |

Secrets (`ASC_*`, `XLESS_DIST_KEY`, `XLESS_DEVID_KEY`) are never part of `xless.yml`; see [README.md](README.md#secrets).
