# Tauri v2 iOS apps

xless builds a [Tauri v2](https://v2.tauri.app/) iOS app on Linux and ships it to TestFlight, with no Mac and no Xcode on the build machine. The app repository stays untouched: everything xless needs to know lives in an **overlay** file kept outside it.

```sh
make testflight CONFIG=$HOME/ci/my-app.overlay.yml
```

## What is supported

- **Contract.** xless reproduces `tauri ios build` for **Tauri 2.12.x** (`tauri` crate and `@tauri-apps/cli`, both read from the lockfiles). Another version stops at `prepare` with "outside the contract xless supports". The measurements behind the contract are in [research/tauri-ios-contract.md](research/tauri-ios-contract.md).
- **Project.** The app repository must already be initialised with `tauri ios init`: `src-tauri/gen/apple/project.yml` is committed. xless supports the subset of `project.yml` that `tauri ios init` generates; an unsupported key is refused with its name, and so is a build script it does not know ([`scripts:`](#overlay-reference)).
- **Build.** Release, arm64, device only. xless runs the frontend build command, compiles the Rust library (`cargo`) and the Swift packages for `aarch64-apple-ios`, and links the app. Then the usual stages: assets, finalize, sign, package, upload and TestFlight delivery ([README](README.md#pipeline)).
- **Dependencies.** CocoaPods is not run. A pod that is a prebuilt binary is declared as a [`binaryDependencies`](#overlay-reference) entry (url, sha256 pin). Git submodules in the app repository are refused.
- **Not supported.** Simulator and debug builds, x86_64, Android, macOS, dSYMs, external TestFlight groups, App Store submission.

## Requirements

- The one-time Apple setup from [bootstrap.md](bootstrap.md) (API key, distribution certificate), plus the secrets file described under [One command: TestFlight](README.md#one-command-testflight).
- The `xless-tauri` image, which adds Node, pnpm and the Rust toolchain installer to the xless image: `make base-local sdk-local tauri-local`.
- The app repository is a git checkout. xless copies the **tracked** files of `source:` (and only those) into a work copy under `~/.cache/xless/work/<overlay name>`; the source is never written to. Commit `gen/apple`, the lockfiles and the files the overlay refers to. Untracked and ignored files are not copied: a file the app's `build.rs` downloads into the tree and git ignores (a model, for example) is downloaded again in the work copy, so such a build needs network access.
- A work copy belongs to one source. The first sync records the source in `.xless/source` of the work copy, and a later run of an overlay with the same file name but another source stops at `prepare`; rename one overlay file or delete the work copy.

## The overlay

A starting point is [samples/HelloTauri/xless.overlay.example.yml](../samples/HelloTauri/xless.overlay.example.yml):

```yaml
type: tauri
source: ~/projects/my-app               # the app repository (or a directory inside a git checkout)
bundleID: com.example.myapp
teamID: ABCDE12345
version: tauri
build: dated
privacyManifest: PrivacyInfo.xcprivacy  # next to this file
usesNonExemptEncryption: false
testflight: { groups: [Internal] }
```

### Overlay reference

Relative paths in the overlay (`source`, `privacyManifest`) resolve against the **overlay file's directory**; `~` is expanded. A path in an overlay that points into the app (such as `assets`) is relative to the work copy.

| Key | Meaning |
|---|---|
| `type` | Required. Must be `tauri`. |
| `source` | The app repository, read-only. Required unless `--source <dir>` (or `$XLESS_SOURCE` with `make testflight`) gives it. It may be a subdirectory of a git checkout. |
| `tauri.dir` | Directory holding `tauri.conf.json` and `Cargo.toml`. Default `src-tauri`. |
| `tauri.features` | Cargo features, as `tauri ios build --features`. |
| `bundleID` | Required. The iOS bundle ID. It overrides the `identifier` in `tauri.conf.json`. |
| `teamID` | Required. The 10-character Apple team ID. |
| `version` | `tauri` (default): `CFBundleShortVersionString` comes from `tauri.conf.json`. Or an explicit version. |
| `build` | `dated` (default): `CFBundleVersion` is `<version>.<YYYYMMDDNN>`, chosen above every build of that version already in App Store Connect (see [build numbers](#build-numbers)). Or an explicit build number. |
| `ios.product`, `ios.minimumOS`, `ios.entitlements` | Overrides for the product name, minimum iOS version and entitlements file. |
| `assets` | An asset catalog (`.xcassets`) to use instead of the one in `project.yml`. |
| `launchStoryboard` | A launch storyboard to use instead of the one in `project.yml`. |
| `infoPlist` | A plist file in the work copy used in place of the target's own Info.plist as the source of the keys merged into the generated one. |
| `privacyManifest` | A `PrivacyInfo.xcprivacy` copied into the app. `finalize` requires one for App Store builds. |
| `usesNonExemptEncryption` | `ITSAppUsesNonExemptEncryption`, stamped at `finalize`. App Store Connect asks about export compliance when it is missing. |
| `linkFlags` | Extra linker flags for the app, for example `["-ObjC"]`. |
| `binaryDependencies` | List of prebuilt dependencies that replace CocoaPods. Each has `url` (https), `sha256` (pinned, 64 hex), `extract` (path inside the archive), `to` (relative path in the work copy), optionally `fixes: { minimumOSVersion: "16.0" }` (rewrites the MinimumOSVersion of the framework's Info.plist) and `linkFlags` (flags this dependency needs). Downloads are cached by hash in `~/.cache/xless/downloads`. An `embed: true` dependency whose framework binary is a static archive is linked but not embedded (the build prints a note); rcodesign cannot sign such a framework, and the code is already in the executable. |
| `scripts` | Maps the name of a `project.yml` build script that is not Tauri's own "Build Rust Code" to `ignore`. xless does not run `project.yml` scripts; one that is not listed stops `prepare`. Only ignore a script whose job xless already does or that does not matter for a release. |
| `testflight` | `groups`, `whatToTest`, `locale`: as in [xless.yml](xless-yml.md#testflight). |

### Capabilities

xless enables the bundle-ID capabilities that the App Store Connect API can enable. The increased memory limit (`com.apple.developer.kernel.increased-memory-limit`) is not one of them: enable it by hand for the bundle ID at developer.apple.com/account/resources/identifiers. Then run `sign` (or `ship`) again; xless refreshes the provisioning profile once to pick the capability up, and stops with the manual-enable message if the profile still lacks it.

### Build numbers

With `build: dated`, `prepare` and `build` ask App Store Connect for the builds of this version and pick `<version>.<YYYYMMDDNN>` above all of them (`NN` counts the day's uploads), so a build never sorts below an existing one. The number is recorded under `.xless/build/ios/build-number` in the work copy and reused by every later stage of the run, so credentials (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`) are needed from `prepare` on. `XLESS_BUILD_NUMBER` or `--build-number` replaces the lookup with an explicit number and no App Store Connect call is made (this is how `make test-tauri-linux` runs without credentials). With `build: dated` the override must itself be `<version>.<YYYYMMDDNN>` for the app's version, for example `XLESS_BUILD_NUMBER=1.0.0.2026101501`: a bare number such as `2026101501` would sort above every dated build and block the version, so it is refused. An override given to a run that starts is recorded like a looked-up number, so later stages run without it use the same one. When the app has no App Store Connect record yet, the lookup finds no builds and starts at `NN` = 01 (see [the app record](#creating-the-app-store-connect-app-record)). `make testflight CONFIG=` does not default `XLESS_BUILD_NUMBER`; set it yourself to override `dated`.

## Creating the App Store Connect app record

Same as for any app ([bootstrap.md](bootstrap.md) steps 4 and 5); the API cannot create it.

1. Register the bundle ID from the overlay (`bundleID`) at developer.apple.com, or run `xless ship --config <overlay>` once: `sign` registers it, and the run stops at `upload` with "no app record".
2. App Store Connect, My Apps, **+**, New App. Choose that bundle ID, iOS, and a name.
3. Add your testers to the TestFlight group named in `testflight.groups` (App Store Connect users, for an internal group), then resume with `xless upload --config <overlay>`, or run the command again.

Try a new overlay against a separate test app record first. A build number uploaded to a record cannot be reused or lowered.

## Shipping

```sh
make testflight CONFIG=$HOME/ci/my-app.overlay.yml
# or: scripts/testflight.sh --config $HOME/ci/my-app.overlay.yml [extra xless ship args, e.g. --from upload]
```

The script works in the `xless-tauri` image (`xless-tauri:local-<arch>`, or `XLESS_IMAGE`). The app's build runs third-party code (npm scripts, `build.rs`, proc-macros), so it never runs next to a secret; the script uses three containers:

1. `xless tauri next-build --config <overlay> --source <source>`, with the App Store Connect key only: prints the next `dated` build number (a read-only query; nothing is written). Skipped when `XLESS_BUILD_NUMBER` or `--build-number` is given, or when resuming after `build`.
2. `xless ship --to finalize` with that number in `XLESS_BUILD_NUMBER` and **no** secret file or variable: prepare, build, assets, finalize.
3. `xless ship --from sign` with the secrets: sign, package, upload. No build code runs here.

`--from <stage>` and `--to <stage>` among the extra arguments choose which of the steps run (`--from upload` runs only step 3); other extra arguments go to both `ship` steps. Options and variables are the ones of [One command: TestFlight](README.md#one-command-testflight), plus:

- **Mounts.** The source goes read-only to `/source`, the overlay's folder read-only to `/config`, so a relative `privacyManifest` resolves, and `--source /source` replaces the overlay's own `source:` inside the container. Keep the overlay in its own directory: the folder is visible to the build, so the script stops (exit 2) when it holds the secrets file or one of the secret files, symlinks resolved. Caches (step 2): `~/.cache/xless/work` and `~/.cache/xless/downloads`, and the docker volumes `xless-rustup` and `xless-cargo` for the Rust toolchains; step 3 mounts only the work copy. The first build downloads Rust and compiles the whole dependency graph, which takes several minutes and several GB; later builds are incremental.
- **`source:`.** The script reads the overlay's `source:` itself, from a plain top-level `source: <path>` line (quotes and a trailing comment are fine). Flow style, anchors or a multi-line value are not understood; set `XLESS_SOURCE` then.
- **Source override.** `XLESS_SOURCE=<dir>` takes the place of the overlay's `source:`.
- **Overlay path.** A leading `~/` is expanded, but prefer `$HOME/…` on the command line: `make testflight CONFIG=~/…` reaches make unexpanded under zsh.
- **Native.** On a Linux machine with `xless` on PATH it runs the same three steps without docker; step 2 runs with the secret variables removed (`env -u`), but secret *files* stay readable to the build, which runs as your user. Native Tauri builds are untested in this milestone. They need what the image adds to xless: rustup, Node 24 with corepack, LLVM binutils (the distribution's `llvm` package plus `llvm-libtool-darwin`, as `docker/Dockerfile.tauri` installs them) and the `xcrun` shim from `docker/shims/` first on `PATH`. `scripts/install.sh` installs none of these.

Without the script, each step is a command: `xless prepare|build|assets|finalize|sign|package|upload --config <overlay> [--source <dir>] --platform ios`. `build` runs `prepare` first. `xless ship` takes `--from <stage>` and `--to <stage>` to run a range, and `xless tauri next-build --config <overlay> [--source <dir>]` prints the build number the next run would use (read-only). Exit codes are the ones in the [README](README.md#pipeline), with `prepare` = 19.

## `xless tauri inspect`

```sh
xless tauri inspect --config my-app.overlay.yml [--source <dir>]
```

Prints, read-only (nothing is written, `cargo` is not run), what a build would do: the resolved identity (bundle ID, version, minimum OS), whether the Tauri and CLI versions are in contract, the target's sources and system libraries, how every `project.yml` script is handled (`built-in`, `ignore` or `UNHANDLED`; a `built-in` script, the one that runs `tauri ios xcode-script`, is printed in full, because xless does that step itself and executes nothing else of it), the binary dependencies and the next dated build number (only when App Store Connect credentials are set). Run it first when a `prepare` error is unclear.

## Linux parity test

`make test-tauri-linux` builds `samples/HelloTauri` through `finalize` in the `xless-tauri` image (no credentials, no signing) and compares the result with `samples/HelloTauri/reference/reference.json`, recorded from `tauri ios build` on a Mac: linked libraries, platform and minimum OS, rpaths, files and Info.plist. It exits non-zero on any difference not listed in `samples/HelloTauri/reference/allowed-gaps.txt`; the gaps are explained in [research/parity-known-gaps.md](research/parity-known-gaps.md#tauri-ios).

## Troubleshooting

Errors read `[stage] cause — fix`. Exit codes: config 10, prepare 19, build 12, assets 13, finalize 14, sign 15, package 16, upload 17.

| Exit | Stage and message | What to do |
|---|---|---|
| 10 | `[config] overlay … is invalid` / `teamID` / `bundleID` / `sha256` | The overlay does not match [the reference](#overlay-reference); the message names the key. |
| 10 | `[config] cannot read overlay`, `has no source` | Check the `--config` path; set `source:` or pass `--source`. |
| 19 | `outside the contract xless supports` | The app's `tauri` crate or `@tauri-apps/cli` is not 2.12.x. Pin both, or wait for a newer contract. |
| 19 | `cannot find the @tauri-apps/cli version` | Commit the JS lockfile, or list `@tauri-apps/cli` in `package.json`. |
| 19 | `is not inside a git repository`, `is a git submodule` | Point `source:` into a git checkout; vendor submodule files. |
| 19 | `cannot read the git checkout` | git's own error follows; run `git status` in the source. |
| 19 | `the work copy … was synced from …` | Two overlay files with the same name point at different sources. Rename one, or delete the work copy. |
| 19 | `cannot read … project.yml` | Run `tauri ios init` and commit `src-tauri/gen/apple`. |
| 19 | `project.yml script '…' is not handled` | Add `scripts: { "<name>": ignore }` if xless already covers it. |
| 19 | `unsupported project.yml key` | The project uses a feature outside the supported subset. Remove it or report it. |
| 19 | `sha256 is …, overlay pins …` | The download changed. Verify it, then update `binaryDependencies[].sha256`. |
| 12 | `[build] …` with a cargo, swift or link error | The tail of the tool's output is printed. A crate that needs a Mac-only tool is a known risk for C and C++ build scripts; check it builds with `cargo build --target aarch64-apple-ios --release` in the image. |
| 12 | `plugin … depends on remote Swift package …, which xless does not pin` | A plugin's `ios/Package.swift` needs a Swift package from the network other than SwiftRs; xless builds with pinned versions only. Report it. |
| 10 | `[config] build: dated needs App Store Connect credentials`, or an App Store Connect or network error while choosing the build number | `build: dated` needs App Store Connect credentials from `prepare` on; set them, or pass `XLESS_BUILD_NUMBER=<version>.<YYYYMMDDNN>`. |
| 10 | `[config] build '…' is invalid for a dated build of version …` | An override of a `build: dated` overlay must be `<version>.<YYYYMMDDNN>`. |
| 14 | `no PrivacyInfo.xcprivacy in the bundle` | Set `privacyManifest:` in the overlay. |
| 14, 15, 16, 17 | | As for any xless project: [README troubleshooting](README.md#troubleshooting). |

If the exit code is 2, the problem is in `scripts/testflight.sh`'s own arguments or configuration (a missing secret variable, overlay or source directory).
