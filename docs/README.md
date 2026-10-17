# xless

xless builds, signs and ships Apple-platform apps from Linux. It takes a SwiftPM project plus an `xless.yml` and produces:

- iOS/iPadOS: a signed `.ipa`, uploaded to App Store Connect (TestFlight).
- macOS: a Developer ID signed, notarized and stapled `.app` inside a `.zip`. A SwiftPM `xless.yml` project gets no `.dmg` (a Tauri v2 macOS app does: see [notarized DMG](#one-command-notarized-dmg-tauri-macos)); there is no Mac App Store `.pkg` ([why](research/mas-pkg.md)) and no upload step for macOS.

It does this without Xcode on the build machine. The Darwin SDK comes from a copy of Xcode 27.0 (27A266a) that you export once on a Mac. Only this Xcode generation is supported.

Docs: [bootstrap.md](bootstrap.md) (one-time Apple setup), [xless-yml.md](xless-yml.md) (config reference), [tauri.md](tauri.md) (Tauri v2 iOS and macOS apps), [react-native.md](react-native.md) (React Native / Expo iOS apps, with app extensions), [research/](research/) (notes on App Store Connect upload, Mac App Store `.pkg`, and known parity gaps).

## Apple software

xless contains and distributes no Apple software: no Xcode, no SDKs, no Apple tools. You obtain Xcode from Apple yourself and are responsible for complying with its license terms. Images that contain an SDK you exported are built locally and are not meant to be published.

If you push images anyway: `make sdk-push` refuses to push unless `registry.env` sets `XLESS_REGISTRY_PRIVATE=true` (checked by `scripts/check-private-registry.sh`, which also refuses Docker Hub: `docker.io`, `index.docker.io`, `registry-1.docker.io` in any case, and bare names such as `myuser`, which Docker would push to Docker Hub). The base image (`xless-base`) never contains SDK files.

## Pipeline

```
┌─ macOS host (once per Xcode release) ─────────────────────────────┐
│ xless sdk export   → dist/sdk/<arch>/darwin.xtoolsdk               │
│                    → dist/sdk/toolchain-meta.json                  │
│ make base-push sdk-export sdk-push                                 │
│                    → <registry>/xless:xcode27.0-27A266a-v<ver>     │
│                      (linux/arm64 + linux/amd64) → PRIVATE registry│
└───────────────────────────────────────────────────────────────────┘
┌─ Linux (CI / dev box / server / docker run) ──────────────────────┐
│ xless ship = build → assets → finalize → sign → package → upload  │
└───────────────────────────────────────────────────────────────────┘
```

Each stage reads only the previous stage's directory under `.xless/build/<platform>/` and writes only its own, so you can resume a failed run with `xless ship --from <stage>`, stop after a stage with `--to <stage>`, or run one stage on its own. A stage builds into `<dir>.partial` and renames it only on success, so a stage directory exists only if that stage succeeded; a failed stage also removes its previous output.

| Stage | Command | Output | Exit code on failure |
|---|---|---|---|
| prepare | `xless prepare` | Overlays only (`--config`, see [tauri.md](tauri.md), [react-native.md](react-native.md)): work copy, dependencies, toolchains (React Native: `expo prebuild`, `pod install`) | 19 |
| build | `xless build` | `app/` unsigned bundle | 12 |
| assets | `xless assets` | `assets/` (iOS: `Assets.car`; macOS: `.icns`) | 13 |
| finalize | `xless finalize` | `final/` Xcode metadata stamped, binaries patched | 14 |
| sign | `xless sign` | `signed/` | 15 |
| package | `xless package` | `out/` `.ipa`, notarized `.zip`, or (Tauri macOS) notarized and stapled `.dmg` | 16 |
| upload | `xless upload` | `upload.json` (iOS only; rewritten at every state change, so it keeps the build ID if processing fails or times out). With a [`testflight:` block](xless-yml.md#testflight) it then delivers the processed build to your TestFlight groups. | 17 |

Config errors exit 10, SDK errors exit 11, and `prepare` errors exit 19. Errors are printed as `[stage] cause — fix`. Other commands: `xless inspect <bundle> --platform <p>` prints Info.plist and Mach-O build versions as JSON (useful when comparing with an Xcode build); `xless sdk meta|export|install` manage the SDK.

All stage commands take `--platform ios|macos`, `--project <dir>` (default `.`) and `--build-number`.

## Secrets

Secrets come only from environment variables or a `NAME_FILE` variable naming a file with the value. They are never CLI flags and are never logged. xless removes them (and their `_FILE` forms) from the environment of every tool it runs, so package code executed during `build` (SwiftPM macros and plugins) cannot read them from its environment; rcodesign gets keys through mode-0600 temporary files. A file named by a `_FILE` variable is another matter: code that runs on the same machine or in the same container as the build, with the same user, can still read it. `scripts/testflight.sh` with a project directory mounts the secret files into the container that also builds; with `--config` (Tauri and React Native apps) the build runs in a container without any secret ([tauri.md](tauri.md#shipping), [react-native.md](react-native.md#shipping-three-containers)).

| Variable | Purpose | Needed for |
|---|---|---|
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` | App Store Connect API key (Admin role) | sign, upload, macOS notarization, `sign bootstrap` |
| `XLESS_DIST_KEY` | Apple Distribution private key (PEM) | iOS sign |
| `XLESS_DEVID_KEY` | Developer ID Application private key (PEM) | macOS sign |

Values are tolerant of how CI systems mangle them: IDs are trimmed, and PEM values may have CRLF line endings or literal `\n` sequences.

The build number comes from `build` in `xless.yml`, overridden by `XLESS_BUILD_NUMBER` or `--build-number` (the flag wins). App Store Connect requires it to increase within a version across every machine that uploads, your laptop and every CI system (ITMS-90062), so use one monotonic scheme everywhere, for example `XLESS_BUILD_NUMBER=$(( $(date +%s) / 60 ))` (minutes since 1970), as the example workflow does. Don't use a CI run number: it restarts at 1 and collides with numbers uploaded from elsewhere. `upload` declares the version and build found in the `.ipa`; if you pass an override that disagrees with it (for example when resuming in a later minute), it stops and asks you to re-run from `finalize` or drop the override.

## Quick start

First do the one-time Apple setup in [bootstrap.md](bootstrap.md).

### Docker

The image holds xless, xtool, rcodesign and the Darwin SDK. Pull it from your private registry (`docker login` first):

```sh
docker run --rm -v "$PWD":/work -w /work \
  -e ASC_KEY_ID -e ASC_ISSUER_ID -e ASC_KEY_P8 -e XLESS_DIST_KEY -e XLESS_BUILD_NUMBER=$(( $(date +%s) / 60 )) \
  <registry>/xless:xcode27.0-27A266a-v0.1.0 xless ship --platform ios
```

Pass the variables by name (`-e NAME`) so values stay out of your shell history and process list. Output ends up in `.xless/build/ios/out/`.

The container runs as root, so the directories it creates in your project (`.xless/`, and for iOS builds `xtool/` and `.build/`) end up owned by root on a Linux host. Remove them with `sudo rm -rf .xless xtool .build`, or hand them back with `docker run --rm -v "$PWD":/work -w /work alpine chown -R "$(id -u):$(id -g)" .xless xtool .build`.

For GitHub Actions see [.github/workflows/example-ios.yml](../.github/workflows/example-ios.yml). It runs the private image as the job container; set the repo variable `XLESS_IMAGE` and secrets `XLESS_REGISTRY_TOKEN`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `XLESS_DIST_KEY`. The runner is x86_64 and the image is multi-arch; this workflow has not been run yet (needs real secrets).

### One command: notarized DMG (Tauri macOS)

`make dmg CONFIG=<overlay.yml>` builds a Tauri v2 macOS app, universal (arm64 and x86_64), signs it with your Developer ID key, notarizes and staples a DMG, and prints its path. It is `scripts/testflight.sh --config <overlay.yml> --platform macos`: the build runs without any secret, then `sign` and `package` run with `XLESS_DEVID_KEY_FILE` and the App Store Connect key. Details, prerequisites and known gaps: [tauri.md](tauri.md#macos). The exit codes are those in the [pipeline table](#pipeline) (prepare 19, build 12, finalize 14, sign 15, package 16).

### One command: TestFlight

`make testflight PROJECT=<dir>` builds, signs, uploads and delivers an iOS project to TestFlight with `xless ship --platform ios`. It wraps [scripts/testflight.sh](../scripts/testflight.sh), which you can also call directly (extra arguments go to `xless ship`, for example `--from upload`). For an app described by an overlay use `make testflight CONFIG=<overlay.yml>`: a Tauri app ([tauri.md](tauri.md#shipping)) or a React Native / Expo app ([react-native.md](react-native.md#shipping-three-containers)). `ARGS="…"` passes extra arguments, for example `ARGS="--from upload"`.

- **Where it runs.** On macOS, inside the xless Linux image through docker (the image is `xless:local-<arch>` unless `XLESS_IMAGE` says otherwise; the docker context is `DOCKER_CONTEXT`, else `colima-xless` when that context exists, else the current one). On Linux it runs natively when `xless` is on PATH, otherwise through docker. `XLESS_USE_DOCKER=1|0` forces either.
- **Build number.** `XLESS_BUILD_NUMBER` if set, else `$(( $(date +%s) / 60 ))`, which is monotonic across machines ([Secrets](#secrets)). With `CONFIG=` the overlay's `build:` decides instead ([tauri.md](tauri.md#build-numbers)).
- **Secrets.** The script reads the paths of your secret files from the environment, or from a local file that it sources first: `~/.config/xless/testflight.env` (override with `XLESS_TESTFLIGHT_ENV`; it never belongs in git). The files are mounted read-only into the container and values are never printed or put on a command line. With a project directory that is the container that also builds, so package code could read the files; with `CONFIG=` the build runs in a separate container without them ([tauri.md](tauri.md#shipping)).

  ```sh
  # ~/.config/xless/testflight.env
  ASC_KEY_ID=ABC123DEFG                          # the API key's ID
  ASC_ISSUER_ID_FILE=$HOME/keys/asc-issuer-id    # file holding the issuer ID (or set ASC_ISSUER_ID)
  ASC_KEY_P8_FILE=$HOME/keys/AuthKey_ABC123DEFG.p8
  XLESS_DIST_KEY_FILE=$HOME/keys/dist-key.pem    # Apple Distribution private key
  ```
- **Paths.** Relative secret paths are resolved against the current directory. With docker, the secret files and the project must be under a directory the docker VM can see (on macOS usually somewhere under `$HOME`).
- **Result.** xless prints the build number, each group and `available to N testers`; a group with no testers prints a warning on stderr. The exit code is xless's (17 for a failed upload or delivery).
- **Testers.** Internal testers must be App Store Connect users. Add them to the group once in the web UI (Users and Access, then TestFlight); xless creates missing groups but cannot add users. API details: [research/asc-testflight.md](research/asc-testflight.md).

### Building the images (on the Mac)

```sh
cp registry.env.example registry.env     # set XLESS_REGISTRY, and XLESS_REGISTRY_PRIVATE=true once you have verified it is private
make base-push sdk-export sdk-push
```

- `make base-push` builds and pushes `<registry>/xless-base:v<ver>` for arm64 and amd64. The Dockerfile cross-compiles `xless` with Swift's static Linux SDK. Every download (static SDK, xtool, rcodesign) is sha256-pinned in `versions.env`, the single place for versions.
- `make sdk-export` (target `base-local` first) runs `xless sdk export`, which runs `xtool sdk build` inside the per-arch base image with Xcode mounted read-only, and writes `dist/sdk/`.
- `make sdk-push` builds the SDK image on top of the base image and pushes it. It fails unless the registry is marked private.
- `make sdk-local` builds the same image locally without pushing. `make test-linux` runs the unit tests in Linux.
- `make images XCODE=<Xcode.app | Xcode_*.xip> [ARCHS=arm64]` builds the whole local chain (`xless-base`, `xless`, `xless-tauri`, `xless-rn`) from one Xcode and tags it `:local-<arch>-xcode<version>`, for projects that pin that Xcode with `xcode:` ([react-native.md](react-native.md#pinning-the-xcode-sdk)). Its SDK export goes to `dist/sdk-xcode<version>/`. The local targets also take `ARCHS`, `IMAGE_SUFFIX` and `SDK_DIR`.

All of these use the active Docker context. To use a separate engine (for example a dedicated Colima VM), set `DOCKER_CONTEXT`; nothing in the repo hardcodes a context.

The Docker VM must be able to see Xcode. Colima: `colima start --mount /Applications:r --mount $HOME:w`. Docker Desktop does not share `/Applications`; make an APFS clone under your home directory (cheap, copy-on-write) and point `XCODE` at it:

```sh
mkdir -p ~/.cache/xless && cp -cR /Applications/Xcode.app ~/.cache/xless/Xcode.app
make sdk-export XCODE=$HOME/.cache/xless/Xcode.app
```

### Native install

For a Debian/Ubuntu machine (arm64 or x86_64) without Docker:

```sh
scripts/install.sh [--prefix /usr/local]
```

It installs Swift 6.4.0 (via swiftly, if not already present), xtool and rcodesign (checksum-verified), and builds and installs `xless`. It uses `sudo` when not root and is safe to re-run. Then install the SDK, using files from `xless sdk export` on the Mac:

```sh
xless sdk install --xtoolsdk darwin.xtoolsdk --meta toolchain-meta.json   # files for this machine's architecture
# or copy them out of the private SDK image (needs docker):
xless sdk install --image <registry>/xless:xcode27.0-27A266a-v0.1.0
```

The SDK goes to the xtool config directory (`$XDG_CONFIG_HOME/swiftpm/swift-sdks/`, else `~/.swiftpm/swift-sdks/`) and the metadata to `XLESS_TOOLCHAIN_META`, else `$XDG_CONFIG_HOME/xless/toolchain-meta.json` (`~/.config/xless/toolchain-meta.json` when `XDG_CONFIG_HOME` is unset). Installation is staged and swapped in only on success, so a failure leaves any existing install untouched. The `--image` form copies out of the image with `docker create`/`docker cp`. `docker create` pulls the image if it is not present locally, so run `docker login <registry>` for your private registry first.

Then, from the project directory: `xless ship --platform ios`.

## Troubleshooting

`xless upload` maps App Store Connect errors to explanations; unknown codes are printed verbatim. Network calls retry only on HTTP 5xx, 429 and transport errors (at most 5 attempts); nothing else is retried.

| Symptom | Meaning and fix |
|---|---|
| 90725 | The SDK version in a binary's `LC_BUILD_VERSION` was not patched. This is an xless bug; report it with `xless inspect` output. |
| 90189, 90062, "bundle version must be higher", "Redundant Binary" | This build number was already uploaded, or is not higher than an earlier upload of this version (from any machine). Use a higher one (`--build-number` / `XLESS_BUILD_NUMBER`, see [Secrets](#secrets)) or bump `version`. |
| 90717 | An app icon has an alpha channel. Re-export it without transparency. |
| 90022, 90023, 90713, 90704 | App icon problem. See [known gaps](research/parity-known-gaps.md). |
| 90135 | A binary carries a secure timestamp. App Store signing must use no timestamp server. This is an xless bug if you see it. |
| 90562 | `Assets.car` is invalid. Check it with `xcrun assetutil --validate-file Assets.car` on a Mac (`make parity` does this), retry without `assets:` to isolate, and report it as an xless bug (AssetKit is vendored in `ThirdParty/AssetKit`). See [known gaps](research/parity-known-gaps.md). |
| 90534, 90111, "Invalid Toolchain" | App Store Connect rejected the toolchain metadata. Compare `xless inspect` with an Xcode build using `make parity`. |
| 90683 | A usage-description string (`NS…UsageDescription`) is missing. Add it via `infoPlist` in `xless.yml`. |
| 91053, "privacy manifest" | The privacy manifest lacks a required-reason API declaration. Update `PrivacyInfo.xcprivacy`. |
| 90208, "MinimumOSVersion" | Info.plist `MinimumOSVersion` disagrees with the binary. Align the `platforms` in `Package.swift` with `xless.yml`. |

Other things worth knowing:

- Apple's upload requirements (checked 2026-10-13): built with SDK 26 or later; iOS minimum OS 13.0 or later. `finalize` refuses older SDKs.
- Loose `.dylib` files are rejected at `finalize`; xless does not wrap them as frameworks.
- `finalize` refuses a Mach-O image whose LINKEDIT tables `dyld` would reject as misaligned (the app would crash at launch); `xless inspect` lists them per binary (`linkeditProblems`).
- The App Store Connect app record cannot be created through the API; create it by hand after the bundle ID is registered ([bootstrap.md](bootstrap.md) steps 4 and 5).

## Known gaps

- One `Assets.car` difference from Xcode output that matters (no MultiSized Image rendition for the app icon) comes from AssetKit; transparent images and colorsets now match actool's (`Opaque`, colour space, scale). See [research/parity-known-gaps.md](research/parity-known-gaps.md).
- Single-size app icon sets with dark or tinted variants are not handled. xless falls back to AssetKit's output, and the resulting `CFBundleIcons` may be malformed (not verified against App Store Connect). Use a plain single 1024px icon.
- Whether App Store Connect accepts the build despite these gaps has not been confirmed (needs a real upload).
- AssetKit (pinned in `versions.env`) is MIT-licensed (its `LICENSE` file at revision e763558), so it can be vendored.
- The Apple limits that `sign bootstrap` enforces (3 Distribution, 5 Developer ID certificates per team) are unconfirmed against Apple documentation.
- App Store Connect upload API notes: [research/asc-build-uploads.md](research/asc-build-uploads.md).
