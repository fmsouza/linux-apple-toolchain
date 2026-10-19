# Milestone 3 acceptance (2026-10-17) — React Native / Expo iOS on Linux

| Criterion (spec §5) | Result |
|---|---|
| 1. `samples/HelloRN` (Expo, native modules, one app extension) builds on Linux and matches the Mac reference | PASS — `scripts/test-rn-linux.sh` (linux/arm64 image): from a fresh prepare, then again offline (`--network none`); the app and `HelloExtension.appex` match `samples/HelloRN/reference/` (executables, linked libraries, rpaths, embedded frameworks, every file, Info.plists, asset catalogs rendition by rendition) with no allowed gaps beyond the documented app-icon one; `main.jsbundle` is Hermes bytecode; every Mach-O passes the LINKEDIT check; the simulator build launches on the iOS Simulator |
| 2. A React Native wallet app builds on Linux from a work copy, leaving its checkout untouched | PASS — private acceptance app (257 targets in 6 projects, CocoaPods, 17 embedded frameworks, 1 app extension, 1 remote Swift package) built through an overlay in the linux/arm64 `xless-rn` image pinned to Xcode 26.2 (the Xcode its own pipeline uses; Swift 6.2.3); Swift Build ran about 6 min; the checkout's `git status --porcelain --ignored` fingerprint was identical before and after every run |
| 3. The app reaches TestFlight `VALID` under a test bundle ID and installs on an iPhone | PASS — `make testflight CONFIG=<overlay>`: dated build number `<version>.<YYYYMMDDNN>`; the build ran in a container with no secret, signing in the base image with no build code; app and extension each signed with their own App Store profile; `VALID`, delivered to the internal group; before upload every Mach-O passed macOS `dyld_info -validate_only` and the simulator build of the same source launched |
| 4. Launches and navigates on the iPhone (smoke test) | PASS — launches, splash screen identical to the Xcode-built app, navigates (user-confirmed) |

Capabilities and portal steps:
- enabled through the App Store Connect API: push notifications, associated domains, AutoFill credential provider, app groups;
- enabled by hand in the developer portal: App Attest, Declared Age Range;
- app groups created and assigned by hand: one (the API cannot create or assign app groups);
- identifiers mapped with `identifiers.replace` (entitlements and Info.plists of the app and its extension): the app's own identifier prefix to the test bundle ID; nothing removed.

Issues found during acceptance and fixed in xless:
- llvm-strip left the LINKEDIT string pool 4-byte aligned; dyld refused the image at launch — the strip shim re-lays LINKEDIT, and finalize refuses any image dyld would reject.
- The image's iOS 27 SDK makes UIKit require the scene life cycle, which the app (built by its own pipeline with Xcode 26.2) does not adopt — per-project `xcode:` pin with images per Xcode, each compiling with an open-source Swift release matching that Xcode's Swift.
- `identifiers.replace` did not reach Info.plist values the app reads at runtime — it now covers the Info.plists of the app and its extensions.
- Every asset-catalog bitmap was marked opaque (transparent images drew black) and named colors were unreadable — AssetKit writes opacity and colors as actool does; the parity check compares asset catalogs rendition by rendition.
- Build outputs cached inside `node_modules` survived a toolchain change — a toolchain change reinstalls JS dependencies and clears derived data.
- An intermittent first-build failure (prebuilt frameworks switched mid-build) — prepare runs the pods' configuration switches.

Known gaps: [react-native.md](react-native.md#known-gaps) and `docs/research/react-native-ios-contract.md`.
