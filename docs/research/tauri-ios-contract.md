# Tauri v2 iOS build contract (tauri-cli 2.12.0, tauri 2.12.0, Xcode 27.0 27A266a)

What `tauri ios build` does on a Mac, observed from the outside, so xless can do the same on Linux (spec §3, §11).
Versions: `@tauri-apps/cli` 2.12.0, crates `tauri` 2.12.0, `tauri-build` 2.7.0, `tauri-plugin` 2.6.3,
`tauri-utils` 2.10.0, `swift-rs` 1.0.8, `tauri-plugin-dialog` 2.7.1; Rust 1.97.0; Xcode 27.0 (27A266a), iPhoneOS27.0 SDK.
A different `@tauri-apps/cli` or `tauri` version is off-contract until this document is re-measured.

## Method

`scripts/tauri-ios-reference.sh <app> <out>` (`make tauri-reference APP=… OUT=…`), Mac only:

1. Copies the app's tracked files (`git ls-files`, working-tree contents; files deleted but still tracked are
   skipped) to a fresh temp work copy and runs everything there; the source checkout is never written.
2. Puts logging wrappers for `cargo`, `xcrun` and `swift` first on `PATH`. Each appends its cwd and argv (cargo: plus
   the `TAURI_*`, `IPHONEOS_DEPLOYMENT_TARGET`, `SDKROOT`, `CC*`, `CFLAGS*`, `RUSTFLAGS`, `CARGO_*TARGET*` variables)
   to a JSON-lines log and execs the real tool. The `PATH` survives into Xcode's "Build Rust Code" script phase, so
   the cargo build that `tauri ios xcode-script` starts and every build-script `xcrun`/`swift` call is captured.
3. Installs JS dependencies (lockfile-selected), runs `pod install` only if the Podfile declares pods, then
   `pnpm tauri ios build --export-method app-store-connect --build-number 1 --no-sign --ci -v [--features …]`.
   No signing: `--no-sign`, no team; the archived `.app` is unsigned (`codesign -dv`: "not signed at all").
4. `tauri ios build` does not echo xcodebuild's output, so compile and link lines come from the DerivedData
   activity log (`Logs/Build/*.xcactivitylog`, gzipped transcript) of the work copy's project
   (`scripts/tauri-reference-xcodelog.py`).
5. `xless tauri report` describes the archived app (`gen/apple/build/<scheme>.xcarchive/Products/Applications/*.app`)
   → `reference.json`; `scripts/tauri-reference-normalize.py` merges the logs → `calls.json`, with absolute paths
   rewritten to `$WORK` (work copy), `$DERIVED` (its DerivedData), `$SDK`, `$TOOLCHAIN`, `$DEVELOPER`, `$HOME`,
   `$DARWIN_USER_CACHE_DIR`.

Committed: `samples/HelloTauri/reference/{reference.json,calls.json}`. The private acceptance app's reference is
kept locally and only summarised here as "acceptance app". No Apple binary was inspected
beyond running Xcode's own tools on our builds and `nm`/`ar -t` on the archives cargo produced.

## Sequence observed

1. `cargo metadata --no-deps --format-version 1` (in `src-tauri`), six times before the build and once after.
2. `beforeBuildCommand` (`node scripts/build.mjs`) with the hook env below.
3. `xcrun simctl list runtimes --json`; `xcrun agvtool new-version -all 1.0.0.1` in `gen/apple` (stamps
   `CFBundleVersion` = `<version>.<build-number>` into the target's `Info.plist` and the project).
4. `xcodebuild archive` (scheme `<name>_iOS`, configuration `release`). Its "Build Rust Code" phase runs
   `pnpm tauri ios xcode-script …`, which talks back to the running `tauri ios build` over a local JSON-RPC
   socket (`gen/apple/.tauri/cli-options-server.json`); without the parent process the phase fails, so the project
   cannot be built with plain `xcodebuild`.
5. xcode-script runs `cargo build` (below) and copies `target/aarch64-apple-ios/release/lib<lib>.a` to
   `gen/apple/Externals/arm64/release/libapp.a`.
6. Xcode compiles `Sources/<name>/main.mm`, links, compiles assets/storyboard, archives; tauri exports
   `gen/apple/build/arm64/<Product>.ipa`.

## Environment

### `beforeBuildCommand` hook (from tauri's `-v` log)

| Variable | HelloTauri | Acceptance app |
|---|---|---|
| `TAURI_ENV_PLATFORM` | `ios` | same |
| `TAURI_ENV_ARCH` | `aarch64` | same |
| `TAURI_ENV_TARGET_TRIPLE` | `aarch64-apple-ios` | same |
| `TAURI_ENV_FAMILY` | `unix` | same |
| `TAURI_ENV_PLATFORM_VERSION` | `27.0.1` (the build host's macOS version, not the SDK's) | same |

`TAURI_ENV_DEBUG` is not set for a release build. None of the `TAURI_ENV_*` variables reach cargo.

### cargo

argv (cwd `$WORK`, the app root):

```
cargo build --package hello-tauri --manifest-path $WORK/src-tauri/Cargo.toml --target aarch64-apple-ios
            --features "tauri/custom-protocol tauri/custom-protocol" --lib --release --color always
```

Acceptance app: `--package <its package> --features "<its features> tauri/custom-protocol tauri/custom-protocol"`
(the `--features` from the CLI first). `tauri/custom-protocol` appears twice, as one argument.

| Variable | Observed (HelloTauri) | Notes |
|---|---|---|
| `SDKROOT` | `$SDK` (iPhoneOS27.0.sdk) | set by Xcode for the script phase |
| `IPHONEOS_DEPLOYMENT_TARGET` | `16.0` | from `bundle.iOS.minimumSystemVersion` via the project |
| `CFLAGS_aarch64_apple_ios` | `-isysroot $SDK` | set by xcode-script |
| `CFLAGS_x86_64_apple_darwin` | `-isysroot $SDK/../../../../MacOSX.platform/Developer/SDKs/MacOSX.sdk` | host build scripts; Linux uses its own host toolchain |
| `TAURI_IOS_APP_NAME` | `hello-tauri` | the `gen/apple` project name (Cargo package name) |
| `TAURI_IOS_PROJECT_PATH` | `$WORK/src-tauri/gen/apple` | |
| `TAURI_CLI_VERBOSITY` | `1` | from `-v` |
| `CCHROOT` | `$DARWIN_USER_CACHE_DIR/com.apple.DeveloperTools/27.0-27A266a/Xcode` | Xcode's own; matched by the `CC*` filter, irrelevant |

Not set: `TAURI_CONFIG` (identifier and version come from the config files; the build number only goes through
`agvtool`), `RUSTFLAGS`, `CC_*`, `CXX_*`, `AR_*`, `CARGO_*TARGET*`. The acceptance app shows the same set.
`cc`-based build scripts therefore find the iOS SDK through `SDKROOT` and Apple clang on `PATH`.

## xcrun calls

| argv | Caller (cwd) | Linux relevance |
|---|---|---|
| `simctl list runtimes --json` | tauri-cli | none (xless does not run tauri-cli's build) |
| `agvtool new-version -all 1.0.0.1` | tauri-cli in `gen/apple` | none (xless stamps `CFBundleVersion` itself) |
| `--sdk iphoneos --show-sdk-path` | swift-rs, once per Swift package (`tauri`, each plugin) | none (§11: no swift-rs on Linux); shim supports it anyway |
| `xcodebuild -version` | swift-rs, once per Swift package (detects Xcode ≥ 27) | none |
| `--sdk macosx --show-sdk-path` | rustc linking host build scripts/proc-macros (~60 calls, one per crate) | none (host is Linux) |
| `--find nm`, `--find libtool` | acceptance app only: its static-library dedupe script (a `project.yml` pre-build script) | replaced by the built-in script mapping |
| `--show-sdk-version --sdk macosx` | acceptance app only: `ring` 0.17.14's build script | host-side; check in spike B |

No `xcrun` call targets the iOS SDK from a C/C++ build script in either build: `cc` uses `SDKROOT`.

## swift calls (swift-rs 1.0.8 via `tauri_utils::build::link_apple_library`)

Per Swift package, in its build script: `swift -target arm64-apple-ios16.0 -print-target-info` (cwd = crate dir), then
`xcrun --sdk iphoneos --show-sdk-path`, `xcrun xcodebuild -version`, then (cwd = the package dir):

```
swift build --sdk $SDK -c release --triple arm64-apple-ios16.0
            --build-path $WORK/src-tauri/target/aarch64-apple-ios/release/build/<crate>-<hash>/out/swift-rs/<package>
            -Xcc --target=arm64-apple-ios16.0 -Xcxx --target=arm64-apple-ios16.0
```

`--triple` (not `--arch` plus `-Xswiftc -sdk/-target`) is swift-rs's Xcode ≥ 27 path; the triple's iOS version is
the plugin's minimum clamped to ≥ 15 (here 16.0, from `IPHONEOS_DEPLOYMENT_TARGET`).

| # | Package dir | Product |
|---|---|---|
| 1 | `$HOME/.cargo/registry/…/tauri-2.12.0/mobile/ios-api` | `Tauri` |
| 2 | `$WORK/src-tauri/plugins/hello-plugin/ios` | `tauri-plugin-hello` |
| 3 | `$HOME/.cargo/registry/…/tauri-plugin-dialog-2.7.1/ios` | `tauri-plugin-dialog` |

Order follows cargo's build-script scheduling and is not stable (`tauri` first; plugins in parallel). Acceptance
app: `Tauri`, then its two local plugins' `ios/` packages, then `tauri-plugin-dialog-2.7.1/ios`.
`tauri-plugin-fs` (a dependency of dialog) has no iOS package. Before building a plugin, `tauri-plugin` copies
`ios-api` to `<plugin>/.tauri/tauri-api` — for registry plugins that is inside `~/.cargo/registry`.

Each package's static library contains its own module plus copies of `Tauri.o` and `SwiftRs.o`, so `libapp.a`
(HelloTauri: 528 members) holds three `Tauri.o` and three `SwiftRs.o` — the duplicate-object situation spec §11
removes by building one aggregate package.

**SwiftRs is fetched from GitHub** (`Tauri`'s `Package.swift`: `swift-rs` `from: "1.0.0"`). Each package resolves it
on its own: `ios-api` and `tauri-plugin-dialog` ship a `Package.resolved` pinning SwiftRs 1.0.7; `hello-plugin`
pins 1.0.9 (its committed `ios/Package.resolved`). This matters on Xcode 27: SwiftPM emits `@_cdecl` functions of a
static product as local symbols unless they are `public`. SwiftRs 1.0.7's `retain_object`/`release_object`/
`string_from_bytes` are internal (local `t` in every 1.0.7 archive); 1.0.9 makes them `public` (global `T`).
swift-rs only re-globalises the package's *own* `@_cdecl` exports (`init_plugin_*`), with rustup's
`llvm-objcopy`. The cdylib that cargo also links (crate-type `cdylib`) then needs at least one archive with a global
SwiftRs copy; HelloTauri has one (hello-plugin, 1.0.9).

## Native compile

One `CompileC` per source: `$TOOLCHAIN/usr/bin/clang -x objective-c++ … -target arm64-apple-ios16.0 -isysroot $SDK
… -c Sources/hello-tauri/main.mm` with Xcode's default warning set and a response file holding
`-std=gnu++14 -stdlib=libc++ -fobjc-arc -fobjc-weak -fmodules -fno-cxx-modules -gmodules -fpascal-strings -Os
-fno-common -DNS_BLOCK_ASSERTIONS=1 -DOBJC_OLD_DISPATCH_PROTOTYPES=0 -g -fvisibility=hidden
-fvisibility-inlines-hidden` plus header-map/include paths (full line in `calls.json` → `compile`). The
acceptance app also compiles the CocoaPods-generated `Pods_<target>_vers.c`.

## Link line (HelloTauri)

`$TOOLCHAIN/usr/bin/clang++` (the ld64-compatible Apple linker behind it), inputs in order:

| Group | Arguments |
|---|---|
| target | `-target arm64-apple-ios16.0 -isysroot $SDK -Os` |
| linker flags | `-Xlinker -reproducible -Xlinker -no_warn_duplicate_libraries` |
| library search | `-L$DERIVED/…/EagerLinkingTBDs/release-iphoneos -L$DERIVED/…/BuildProductsPath/release-iphoneos -L$WORK/src-tauri/gen/apple/Externals/arm64/release -L$SDK/usr/lib/swift -L$TOOLCHAIN/usr/lib/swift/iphoneos -L$TOOLCHAIN/usr/lib/swift-5.0/iphoneos` |
| framework search | `-F$DERIVED/…/EagerLinkingTBDs/release-iphoneos -F$DERIVED/…/BuildProductsPath/release-iphoneos -F.` |
| objects | `-filelist …/HelloTauri.LinkFileList` = `main.o` only |
| rpath, stripping | `-Xlinker -rpath -Xlinker @executable_path/Frameworks -Xlinker -dead_strip` |
| LTO/bookkeeping | `-Xlinker -object_path_lto <…_lto.o> -Xlinker -final_output -Xlinker /Applications/HelloTauri.app/HelloTauri -Xlinker -dependency_info <…>` |
| runtime | `-stdlib=libc++ -fobjc-arc -fobjc-link-runtime` |
| libraries | `-lapp` |
| SDK frameworks | `-framework CoreGraphics Metal MetalKit QuartzCore Security UIKit WebKit` (one `-framework` each, `project.yml` order) |
| output | `-o $DERIVED/…/InstallationBuildProductsLocation/Applications/HelloTauri.app/HelloTauri` |

No explicit Swift libraries and no `libclang_rt.ios.a`: the Swift runtime and the overlays come from autolink
records in the Swift objects inside `libapp.a`, through the `-L…/swift` paths; the clang driver adds its own
runtime. The executable's load commands (`reference.json`) list 38 libraries: the seven SDK frameworks, Foundation,
AVFoundation, CoreFoundation, CoreMedia, CoreServices, ImageIO, Photos, PhotosUI (autolinked by the dialog plugin),
`libobjc`, `libc++`, `libSystem` and 20 `/usr/lib/swift/libswift*.dylib`. Platform 2 (iOS), minos 16.0,
one rpath `@executable_path/Frameworks`, no `Frameworks/` directory (no Swift stdlib embedded at minos ≥ 15).

Acceptance-app differences, all from a binary xcframework dependency it takes from CocoaPods: `-F` for the pod's
directory (absolute and relative), and before `-lapp`: `-ObjC -lc++ -framework <xcframework> -weak_framework <SDK
framework>` (from the CocoaPods xcconfig), then `-lapp -framework <xcframework>`, the seven SDK frameworks and
`-framework Pods_<target>`; the xcframework's slice is embedded under `Frameworks/`, and the weakly linked SDK
framework is the one extra linked library. xless has no CocoaPods: the xcconfig-derived flags have to come from
the overlay's binary-dependency entry (open question 4).

## Bundle (HelloTauri `reference.json`)

`AppIcon60x60@2x.png`, `AppIcon76x76@2x~ipad.png`, `Assets.car`, `HelloTauri`, `Info.plist`,
`LaunchScreen.storyboardc/{Info.plist,UIViewController-Y6W-OH-hqX.nib,Y6W-OH-hqX-view-5EZ-qb-Rvc.nib}`, `PkgInfo`,
plus an empty `assets/` folder reference (not listed: the report lists files only). `CFBundleVersion` is
`1.0.0.1` (excluded from comparison as volatile). `src-tauri/Info.ios.plist` (UIScene adoption, which iOS 27 enforces at
launch) is dict-merged into the target's `Info.plist` by tauri-cli before xcodebuild runs: the product carries
`UIApplicationSceneManifest = {UIApplicationSupportsMultipleScenes: true, UISceneConfigurations: {}}` alongside
the `project.yml` `info.properties`. No entitlements are embedded in the unsigned build; the
template's `hello-tauri_iOS.entitlements` is an empty dict.

## Findings for xless

1. `tauri ios build` checks `bundle.resources` paths before `beforeBuildCommand`. An app whose `build.rs` stages
   its resources (the acceptance app) fails on a fresh checkout with `resource path … doesn't exist`; the reference
   build creates the empty directories first (`REF_PRE_BUILD`). xless runs cargo itself and is not affected, but
   must not demand resource dirs before cargo has run.
2. On Xcode 27.0 the acceptance app does not build from a clean work copy as committed: all four of its Swift
   packages (`Tauri`, the dialog plugin, its two local plugins) pin SwiftRs 1.0.7, so no archive carries a global `_retain_object` and cargo's link of the `cdylib`
   fails (`Undefined symbols: _release_object, _retain_object, _string_from_bytes`). Incremental
   builds survive only on archives left by an earlier Xcode build in which those symbols were global. Its
   reference was produced by deleting the plugins' `Package.resolved` and their swift-rs build dirs *in the work copy* so
   SwiftPM resolved SwiftRs 1.0.9. On Linux the aggregate package resolves SwiftRs once. *Superseded by spike A
   ([SwiftRs](#swiftrs-open-question-2) below):* the Xcode 27 symptom does not reproduce on Linux, where non-public
   `@_cdecl` functions come out `private external` and link, so 1.0.7 links too; ≥ 1.0.9 is not required. xless pins
   1.0.9 anyway, because it is what the Mac reference effectively used.
3. The project's `Build Rust Code` phase cannot run without `tauri ios build` as parent, confirming spec §4.5:
   xless re-implements the phase instead of executing it.

## Open questions

1. `TAURI_ENV_PLATFORM_VERSION` is the host macOS version on the Mac. What should xless pass on Linux: the SDK
   version (27.0), or leave it unset? **Answered (spike A):** the SDK version, see below.
2. SwiftRs resolution on Linux needs network access to GitHub (or a vendored copy) and a pinned version; which
   version does the aggregate package pin, given `ios-api` pins 1.0.7? **Answered (spike A):** 1.0.9 through a
   generated `Package.resolved`; the crates ship no `Package.resolved` at all, see below.
3. Does xless build the `cdylib`/`rlib` crate types too (cargo builds all three from `--lib`), or restrict to
   `staticlib` (`cargo rustc --crate-type staticlib`)? The cdylib is the step that fails in finding 2 and is unused
   on iOS. **Answered (spike A):** `staticlib` only, see below.
4. Where do the CocoaPods-derived link flags of the acceptance app (`-ObjC`, `-lc++`, `-weak_framework <SDK
   framework>`) live in the overlay: per binary dependency, or generic `linkFlags`? **Answered (spike B):** the
   podspec's `libraries`/`weak_frameworks` per binary dependency, `-ObjC` in generic `linkFlags`, see below.
5. The duplicate `-framework <xcframework>` and the `Pods_<target>` framework in the acceptance app's link: confirm
   both can be dropped on Linux (spike B). **Answered (spike B):** both dropped, no change, see below.
6. `ring`'s `xcrun --show-sdk-version --sdk macosx` on the Mac: does its build script make an iOS-SDK call on a
   Linux host that the shim must answer? **Answered (spike A):** no, see below.

## Linux build — spike A findings

`scripts/spikes/hellotauri-linux.sh` (labelled spike; executable documentation for Task 11) builds HelloTauri in
`xless-tauri:local-arm64` (Swift 6.4, Darwin SDK iPhoneOS27.0, `ld64.lld`) from a work copy in the `/cache/work`
volume, with no tauri-cli and no Xcode. **Result: the gate passes.** The executable's linked libraries (38, the same
set as `reference.json`; only the order differs), platform (2), minos (16.0) and rpaths (`@executable_path/Frameworks`)
match the reference: `xless tauri compare reference.json <app> --allow-file <gap list>` exits 0 with a gap list that
names only `file:` and `plist:` keys (bundling was not in scope), and the unfiltered compare reports no `lib:`,
`rpath:` or `exe:` line. Clean run (registry, rustup toolchain and pnpm store warm): ~80–140 s, of which cargo is
65–115 s, the Swift aggregate 10–13 s and the link 1 s. The first rustup bootstrap adds ~70 s.

### Sequence and exact settings

1. Work copy: `git ls-files` of the sample, rsynced. Rust: `rustup-init -y --no-modify-path --default-toolchain none`,
   then `rustup toolchain install` (no argument: the toolchain, targets and components of `rust-toolchain.toml`).
2. Frontend: `corepack pnpm install --frozen-lockfile`, then `beforeBuildCommand` with the `TAURI_ENV_*` hook env;
   `TAURI_ENV_PLATFORM_VERSION` = `xcrun --sdk iphoneos --show-sdk-version` (27.0).
3. Cargo (cwd = app root):

   ```
   SDKROOT=<iPhoneOS SDK> IPHONEOS_DEPLOYMENT_TARGET=16.0
   TAURI_IOS_APP_NAME=hello-tauri TAURI_IOS_PROJECT_PATH=<work>/src-tauri/gen/apple
   CC_aarch64_apple_ios=clang CXX_aarch64_apple_ios=clang++ AR_aarch64_apple_ios=llvm-ar
   CFLAGS_aarch64_apple_ios="--target=arm64-apple-ios16.0 -isysroot $SDKROOT"   (CXXFLAGS_… the same)
   CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=clang CC_aarch64_unknown_linux_gnu=clang CXX_aarch64_unknown_linux_gnu=clang++
   cargo rustc --package hello-tauri --manifest-path src-tauri/Cargo.toml --target aarch64-apple-ios
               --features "tauri/custom-protocol tauri/custom-protocol" --lib --release --crate-type staticlib
   ```

   - The `*_unknown_linux_gnu` settings are needed because the image has no `cc`: rustc's default host linker and
     the `cc` crate's default host compiler are both `cc` (`error: linker 'cc' not found`). The host triple follows
     `uname -m` (`X86_64_UNKNOWN_LINUX_GNU` on amd64). clang then links host build scripts with gold, which rustc
     warns about (`the gold linker is deprecated`); harmless here. A `clang -fuse-ld=lld` linker wrapper would
     silence it (`ld.lld` is in the image), not tried.
   - `--target=` in `CFLAGS_aarch64_apple_ios` because the image's clang defaults to `aarch64-unknown-linux-gnu`;
     objc2-exception-helper is the only C code compiled for iOS here.
   - Output: `target/aarch64-apple-ios/release/libhello_tauri_lib.a`, no `__swift5_*` section in any member.
4. Swift packages, from `cargo metadata --format-version 1 --filter-platform aarch64-apple-ios`: `tauri`'s
   `mobile/ios-api`, `tauri-plugin-dialog` 2.7.1's `ios/` and `hello-plugin`'s `ios/` (`tauri-plugin-fs` has a
   `tauri-plugin` build-dependency but no `ios/Package.swift`). Staged into `.xless/swift/` as:

   ```
   .xless/swift/plugins/.tauri/tauri-api/      ← ios-api (minus .build, Package.resolved, Tests), ONE copy
   .xless/swift/plugins/tauri-plugin-dialog/   ← its ios/ (same excludes)
   .xless/swift/plugins/tauri-plugin-hello/    ← its ios/
   .xless/swift/Aggregate/{Package.swift,Package.resolved,Sources/XlessTauriSwift/XlessTauriSwift.swift}
   ```

   The aggregate manifest is the Task 10 text with these paths: `.package(name: "Tauri", path:
   "../plugins/.tauri/tauri-api")` and `.package(name: "<product>", path: "../plugins/<crate name>")`.
5. `swift build -c release --package-path .xless/swift/Aggregate --build-system swiftbuild --triple arm64-apple-ios16.0
   --toolset <bundle>/toolset-swb.json --force-resolved-versions`, with `SDKROOT` unset,
   `XCODE_EXTRA_PLATFORM_FOLDERS=<bundle>/Developer/Platforms` and `<bundle>/toolset/bin` first on `PATH` (the
   invocation `MacBuilder` already uses). Product: `.build/out/Products/Release-iphoneos/libXlessTauriSwift.a`,
   13 members, each module once (`Tauri` 8 objects, `SwiftRs` `lib.o`, `DialogPlugin.o`, `FilePickerController.o`,
   `HelloPlugin.o`, the empty `XlessTauriSwift.o`): a static library product does carry its dependencies' objects.
6. Symbols: the Swift FFI that `libhello_tauri_lib.a` imports (`llvm-nm -u`) is exactly `_init_plugin_dialog`,
   `_init_plugin_hello`, `_log_stdout`, `_register_plugin`, `_run_plugin_command`, `_on_webview_created` (tauri's
   `ios.rs`) and `_retain_object`, `_release_object`, `_string_from_bytes` (swift-rs). All nine are `T` in
   `llvm-nm -g --defined-only` of the aggregate. No `llvm-objcopy --globalize-symbol` was needed.
7. Compile `Sources/hello-tauri/main.mm` with Xcode's flags minus header maps, `-g`/`-gmodules` and diagnostics
   plumbing (`clang -x objective-c++ -target arm64-apple-ios16.0 -isysroot $SDK -std=gnu++14 -stdlib=libc++ -fobjc-arc
   -fobjc-weak -fmodules -fno-cxx-modules -fpascal-strings -Os -fno-common -DNS_BLOCK_ASSERTIONS=1
   -DOBJC_OLD_DISPATCH_PROTOTYPES=0 -fvisibility=hidden -fvisibility-inlines-hidden -c`), then link:

   ```
   clang++ -target arm64-apple-ios16.0 -isysroot $SDK -Os -fuse-ld=<bundle>/toolset/bin/ld64.lld -mlinker-version=907
     -L target/aarch64-apple-ios/release -L $SDK/usr/lib/swift -L $TOOLCHAIN/usr/lib/swift/iphoneos
     main.o -Xlinker -rpath -Xlinker @executable_path/Frameworks -Xlinker -dead_strip
     -stdlib=libc++ -fobjc-arc -fobjc-link-runtime -lhello_tauri_lib <aggregate .a> $TOOLCHAIN/usr/lib/clang/21/lib/darwin/libclang_rt.ios.a
     -framework CoreGraphics -framework Metal -framework MetalKit -framework QuartzCore -framework Security
     -framework UIKit -framework WebKit -o HelloTauri
   ```

### Fixes the Mac line needed on Linux (and why)

| Change | Reason / evidence |
|---|---|
| `-mlinker-version=907` | Without it clang assumes an old ld64 and passes `-iphoneos_version_min 16.0.0`; `ld64.lld` rejects that with `must specify -platform_version` and `missing or unsupported -arch arm64`. With it the driver emits `-platform_version ios 16.0.0 27.0` (clang switches to that form from linker version 520). |
| `-fuse-ld=<bundle>/toolset/bin/ld64.lld` | The SDK bundle's linker (xtool's trampoline in front of `ld64.lld`). |
| Explicit `libclang_rt.ios.a` | Xcode's driver adds it from its resource dir; the Linux clang's resource dir has no `lib/darwin`, so it silently adds nothing. Nothing in HelloTauri needs it (the executable has the same size with and without), kept for parity. `clang/21.0.0` is a symlink to `clang/21`: glob once, not twice. |
| `-lhello_tauri_lib` + the aggregate instead of `-lapp` | xless links cargo's output in place; no `Externals/` copy. |
| Dropped `-reproducible`, `-no_warn_duplicate_libraries`, `-object_path_lto`, `-final_output`, `-dependency_info` | ld64 bookkeeping; not needed for the result. |
| No `-lswift*` / no `-lc++` beyond the driver's | As on the Mac, the Swift runtime and overlays come from the autolink records in the Swift objects through the two `-L…/swift` dirs. |

`ld64.lld` prints `This version of lld does not support linking for platform iOS. Proceed at your own risk.` 15
times; it is a warning only. The comparison did not cover weak vs. strong linkage (`BundleReport` records install
names only); ours weak-links 13 Swift overlays (`libswiftDarwin`, `libswiftCoreFoundation`, `libswiftUIKit`, …).

### Swift package identity (changes Task 10's layout)

SwiftPM's identity of a path package is its directory's last component. Staging every plugin as
`plugins/<name>/ios` fails: `error: Conflicting identity for ios`. Naming the directory after the crate fixes that,
but the plan's per-plugin `plugins/<name>/.tauri/tauri-api` copies then each collide with the aggregate's own
`tauri-api` (`warning: Conflicting identity for tauri-api … will be escalated to an error in future versions of
SwiftPM`); symlinking those copies to one directory does not help (SwiftPM does not resolve symlinks for identity).
Plugins as siblings under `plugins/`, with the single API at `plugins/.tauri/tauri-api`, make every plugin's
`path: "../.tauri/tauri-api"` and the aggregate's dependency the same path: no warning, one `Tauri` module. This
relies on each plugin's manifest using tauri-plugin's `../.tauri/tauri-api` convention, which both plugins here do.

### Deployment target of the Swift objects

`swift build --swift-sdk arm64-apple-ios` (unversioned triple) fails with `error: unable to find platform for
'iphoneos'` unless `XCODE_EXTRA_PLATFORM_FOLDERS` is set; with it, the root module gets minos 16.0 but every
dependency module 15.0 (their manifests declare iOS 11/13/14, raised to the toolchain's floor). `--triple
arm64-apple-ios16.0` gives every member minos 16.0, which is what swift-rs's `--triple arm64-apple-ios16.0` does on
the Mac. Neither changed the executable's linked libraries for HelloTauri, but the versioned triple is the faithful
one.

### SwiftRs (open question 2)

- Neither `tauri-2.12.0.crate` nor `tauri-plugin-dialog-2.7.1.crate` contains a `Package.resolved` (`tar tzf`). The
  1.0.7 pins seen on the Mac were written into `~/.cargo/registry` by SwiftPM during an earlier swift-rs build there
  (SwiftPM writes `Package.resolved` next to the root manifest it builds); the "ships a `Package.resolved`" wording
  in the swift-rs section above describes that registry state, not the crates. On a fresh Linux registry the aggregate
  resolves `from: "1.0.0"` to the newest tag, today 1.0.9.
- Decision: xless writes `Aggregate/Package.resolved` (format version 2) pinning
  `https://github.com/Brendonovich/swift-rs` 1.0.9 at `207e4bfe5d36fdd0cc08f28d1849ff94ac7e24b8` and builds with
  `--force-resolved-versions`. Checked: the same file with 1.0.7/`f64a4514…` makes SwiftPM resolve 1.0.7, so the pin is
  what decides. Resolution fetches from GitHub (about 1 s) into SwiftPM's cache (`~/.cache/org.swift.swiftpm`, not on a
  volume in the spike, so each fresh container fetches again); offline builds need that cache on a volume or a
  mirror.
- The Xcode 27 symptom does not reproduce on Linux: with SwiftRs 1.0.7 pinned, `_retain_object`,
  `_release_object` and `_string_from_bytes` are still listed as `T`. `llvm-nm -m` (on the 1.0.9 build) shows why
  non-public `@_cdecl` functions pass: they are `private external` (N_EXT|N_PEXT, hidden), which resolves in a static link but is not
  exported; the init and tauri FFI symbols are all `private external`, SwiftRs 1.0.9's three are `external`. Only a
  local (`t`) symbol would break the link. 1.0.9 is pinned anyway: it is what the Mac reference effectively used,
  and its exports do not depend on visibility handling.
- Task 10's `checkGlobalSymbols` criterion (`T`/`S`/`D` in `llvm-nm -g --defined-only`) is right, and its pattern
  set is the nine names above: `^_init_plugin_` plus `_log_stdout`, `_register_plugin`, `_run_plugin_command`,
  `_on_webview_created`, `_retain_object`, `_release_object`, `_string_from_bytes`.
- `llvm-nm` must be new enough for Rust's bitcode: the image's `/usr/bin/llvm-nm` is LLVM 14 and exits 1 on the
  crate's staticlib (`Opaque pointers are only supported in -opaque-pointers mode (Producer: 'LLVM22.1.6-rust-1.97.0-stable'
  Reader: 'LLVM 14.0.0')`, on the `compiler_builtins` members). rustup's `llvm-tools` `llvm-nm`
  (`$(rustc --print sysroot)/lib/rustlib/<host>/bin/llvm-nm`) reads both archives.

### Open questions 1, 3 and 6

- **1 — `TAURI_ENV_PLATFORM_VERSION`:** pass the SDK version (`xcrun --sdk iphoneos --show-sdk-version`, 27.0). None
  of the `TAURI_ENV_*` reach cargo (contract above), so it only affects `beforeBuildCommand`; a frontend that reads
  it gets a defined, Apple-side value instead of nothing, and the Mac's host-macOS value has no Linux equivalent.
- **3 — crate types:** `cargo build --lib` on Linux fails at the `cdylib`. First with `error: linker 'cc' not found`
  (rustc's iOS linker default); with an iOS linker configured (`CARGO_TARGET_AARCH64_APPLE_IOS_LINKER=clang` plus
  `--target`, `-fuse-ld`, `-isysroot`, `-mlinker-version` link args) with exactly the nine Swift FFI symbols above
  undefined (`ld64.lld: error: undefined symbol: init_plugin_hello` …), since tauri skips Swift on a Linux host.
  xless uses `cargo rustc … --lib --crate-type staticlib`: one artifact, the one the executable link consumes.
  Switching between `cargo build` and `cargo rustc` only rebuilds the app crate. (HelloTauri needs no linker for the
  iOS target; spike B shows that a dependency with a `cdylib` crate type does, so xless always configures one.)
- **6 — `xcrun` on Linux:** the HelloTauri build makes no `xcrun` call at all: cargo (tauri, objc2-exception-helper's
  `cc` build) none, SwiftPM none; the only logged call is the script's own `--show-sdk-version`. A probe crate
  depending on `ring = "=0.17.14"`, built for `aarch64-apple-ios` with the same env, also makes none, and ring's
  `build.rs` has no `xcrun` reference. The Mac call comes from the `cc` crate (1.2.67, `apple_deployment_target`):
  it runs `xcrun --show-sdk-version --sdk <sdk>` only when `<OS>_DEPLOYMENT_TARGET` is unset, and `xcrun
  --show-sdk-path --sdk <sdk>` only when `SDKROOT` is unset or names the wrong platform. On a Linux host the host
  builds are not Apple, and for iOS both variables are set. The shim answers both forms anyway.

## Linux build — spike B findings (acceptance app)

The acceptance app's full dependency graph built by hand in `xless-tauri:local-arm64`, with the spike A procedure
plus the changes below (script kept locally with the app's reference, not committed). **Result: the gate passes.**
cargo completes (every C build script compiles with clang for `arm64-apple-ios`), the executable links with no
undefined symbol, and its linked libraries are set-equal to the Mac reference's: 39 install names, the same 15 of
them weak, platform 2, minos 16.0, rpath `@executable_path/Frameworks`. `xless tauri compare reference.json <app>
--allow-file <gap list>` exits 0 with a gap list of `file:`/`plist:` keys and `framework:<pod>.framework` (embedding
the pod's framework is bundling, not in scope); the unfiltered compare reports no `lib:`, `rpath:` or `exe:` line.
Stripped (`strip`, as the archive is), the executable is 34.6 MB against the Mac's 34.4 MB.

### Differences from spike A

1. **Toolchain.** The app's `rust-toolchain.toml` pins the channel but lists neither the iOS target nor
   `llvm-tools`. xless runs `rustup target add aarch64-apple-ios` and `rustup component add llvm-tools` itself
   after `rustup toolchain install`; it must not rely on the toolchain file for either.
2. **Binary dependency.** The app's one CocoaPods pod is a vendored static framework (`static_framework: true`; its
   xcframework's `ios-arm64` binary is a universal `ar` archive with one arm64 slice). Its URL comes from the
   CocoaPods trunk podspec (`source.http`), sha256 TOFU; unzipped to `gen/apple/Pods/<pod>/`, the path the app's
   `build.rs` and `project.yml` name. The extracted binary's sha256 equals the copy `pod install` put on the Mac.
   No `pod` run is needed. `ld64.lld` reads the universal archive.
3. **`beforeBuildCommand`.** The platform file's value (`tauri.ios.conf.json`) replaces the base one; run with
   `sh -c` in the app root with the hook env, `pnpm` on `PATH` (a corepack shim). It needs network only for
   `pnpm install`.
4. **iOS linker for cargo.** `cargo rustc --crate-type staticlib` restricts only the app crate. A dependency that
   declares `crate-type = ["cdylib", "rlib"]` (`image-hdr` 0.6.0) is still linked as an iOS dylib, and the first run
   failed there with `error: linker 'cc' not found`. Fix (env only): `CARGO_TARGET_AARCH64_APPLE_IOS_LINKER` = a
   wrapper running `clang -target arm64-apple-ios16.0 -isysroot $SDK -fuse-ld=<bundle>/toolset/bin/ld64.lld
   -mlinker-version=907 "$@" <libclang_rt.ios.a>`. It produced `libimage_hdr-….dylib`; the staticlib does not use it.
   xless sets this linker for every build; it does no harm when nothing needs it.
5. **C code for iOS.** Build scripts that compiled C/asm for `arm64-apple-ios` with the image's clang: `blake3`,
   `libsqlite3-sys` (bundled SQLite), `libwebp-sys`, `objc2-exception-helper`, `ring`. No `zstd-sys` or `aws-lc-sys`
   in this graph. None needed a per-crate setting beyond spike A's `CC_/CXX_/AR_/CFLAGS_/CXXFLAGS_aarch64_apple_ios`.
   No `xcrun` call from cargo or SwiftPM (the shim log has only the script's own `--show-sdk-version`).
6. **The app's `build.rs`.** It downloads its bundled models (network, sha256-checked) and stages
   `.bundle-resources/` and `gen/apple/assets/` before calling `tauri_build::try_build`. So cargo needs network
   unless the models are already in the work copy.
7. **`bundle.resources` directories are not needed before cargo on Linux.** The Mac reference needed its two `bundle.resources`
   directories created empty first because tauri-cli checks `bundle.resources` before
   `beforeBuildCommand`. Within cargo, `tauri-build` 2.7.0 `try_build` copies `bundle.resources` for every target,
   iOS included (`copy_resources`, which fails on a missing path), but that runs inside the app's build script after
   the app's own staging code. A clean work copy without those directories built through cargo, and the directories
   were populated afterwards. Generic rule for xless (finding 1): do not check `bundle.resources` before cargo;
   resolve them when bundling, after cargo.
8. **Swift.** Four packages: `Tauri` (`ios-api`), `tauri-plugin-dialog` 2.7.1 and the app's two local plugins.
   `tauri-plugin-fs` and `tauri-plugin-process` have a `tauri-plugin` build-dependency but no `ios/Package.swift`.
   The aggregate resolves SwiftRs 1.0.9 from the generated `Package.resolved`. Product: 14 members; the ten FFI
   symbols the staticlib imports (three `init_plugin_*` plus the seven fixed names) are all `T`. No
   globalisation needed. The app's Xcode phase also runs a script that dedupes same-named Swift members in
   `libapp.a`. That script exists because cargo's Mac staticlib carries one copy of the Swift objects per package.
   On Linux the staticlib has no Swift objects, so nothing needs it.
9. **Link.** Spike A's line, plus `-F <Pods>/<pod>.xcframework/ios-arm64` and, before the crate library, the pod
   flags `-ObjC -lc++ -framework <pod> -weak_framework <SDK framework>`. Dropped from the Mac line: the second
   `-framework <pod>` and `-framework Pods_<target>`. `main.mm` is compiled as in spike A (`-DCOCOAPODS=1` added; no
   effect). `ld64.lld` prints its "platform iOS" warning 105 times, and nothing else.

### Open questions 4 and 5

Evidence: the link above, repeated with one change at a time (sizes from the same work copy):

| Variant | Links | Linked libraries vs the line above | Size |
|---|---|---|---|
| line above | yes | — (39) | 41 020 224 |
| + second `-framework <pod>` | yes | same | same |
| + a `Pods_<target>` stand-in (CocoaPods' dummy class + version symbols, static) | yes | same | +304 B (its 4 symbols, loaded by `-ObjC`) |
| − `-ObjC` | yes | same | −17 720 B |
| − `-lc++` | yes | same (the driver adds `-lc++` for `clang++ -stdlib=libc++`) | same |
| − `-weak_framework <SDK framework>` | yes | that framework missing (38) | same |
| − `-framework <pod>` | yes | same | same |

- **4:** The flags come from two places. CocoaPods writes them into `Pods-<target>.release.xcconfig` as
  `OTHER_LDFLAGS = -ObjC -l"c++" -framework "<pod>" -weak_framework "<SDK framework>"`. Of these, `-l"c++"` and
  `-weak_framework` are the podspec's `libraries` and `weak_frameworks`, and `-framework` is its
  `vendored_frameworks`. `-ObjC` is CocoaPods' own default. It is not specific to the pod: here `-ObjC` loads one
  extra member (`UiUtils.o`, from the Tauri Swift module in the aggregate) and nothing from the pod. The pod archive
  defines no Objective-C classes, and the app loads the runtime dynamically, so the staticlib imports none of its symbols, so
  `-framework <pod>` contributes no code on either the Mac or Linux. Answer:
  - per binary dependency: `-framework <name>` plus the podspec's `libraries`/`frameworks`/`weak_frameworks`
    (`weak_frameworks` is what decides parity: dropping it loses a linked library);
  - generic `linkFlags`: `-ObjC`, because its effect spans every archive on the line. The overlay that reproduces a
    CocoaPods app lists it.
- **5:** Both can be dropped. The duplicate `-framework <pod>` changes nothing. `Pods_<target>` is a static framework
  holding CocoaPods' `PodsDummy_*` class and version symbols. On the Mac it is not in the executable's linked
  libraries, and adding an equivalent on Linux leaves the linked libraries unchanged.

### Time and disk (arm64 Colima VM, 8 CPUs, 15 GB)

Clean run with the cargo registry, rustup toolchain, pnpm store and pod zip warm: **351 s**. That is sync 4 s, pod
unzip 1 s, `pnpm install` + `beforeBuildCommand` 20 s, cargo 313 s (release profile with `lto = true`,
`codegen-units = 1`; includes the model downloads), Swift aggregate 9 s, link under 1 s. First-time extras: the
pod zip (45 MB) 6 s, a cold `pnpm install` about 15 s more, about 440 MB of crates. Disk: the work volume ends at 3.4 GB
(the `target/` dir 2.2 GB, `node_modules`, the unzipped pod 191 MB, staged assets 2 × 52 MB). The VM's Docker disk
peaked 4.2 GB above its pre-spike level, cargo registry growth included.
