# Milestone 2b acceptance (2026-10-15) — Tauri v2 iOS on Linux

| Criterion (spec §8) | Result |
|---|---|
| 1. `samples/HelloTauri` builds on Linux and matches the Mac reference | PASS — `scripts/test-tauri-linux.sh` (linux/arm64 image): linked libraries, platform, minimum OS, rpaths, Info.plist and app icons match `samples/HelloTauri/reference/reference.json`; remaining gaps listed in `samples/HelloTauri/reference/allowed-gaps.txt` |
| 2. A real Tauri v2 app builds on Linux through an overlay, from a work copy, leaving its checkout untouched | PASS — private acceptance app (Rust + 3 Swift plugins + a CocoaPods-distributed xcframework) built in the linux/arm64 image; `git status --porcelain --ignored` and a size/mtime listing of every file in the checkout identical before and after |
| 3. The test app reaches TestFlight `VALID` and is delivered to an internal group | PASS — `make testflight CONFIG=<overlay>`: dated build number `1.0.0.<YYYYMMDDNN>`, signing keys never mounted into the build container, `VALID`, delivered to the internal group |
| 4. Installs from TestFlight and passes a smoke test on an iPhone | PASS — launches, navigates, folder access works. One import failure (`os error 20`) was traced to app behaviour, not the toolchain: an Xcode-built copy of the same commit imports fine in the simulator, and the failing path comes from the folder chosen on the device |

Issues found during acceptance and fixed in xless:
- cargo linker wrapper name ending in `ld` made rustc use the ld64 flavour (dependency cdylib links failed);
- a CocoaPods xcframework whose binary is a static archive broke `finalize`, and rcodesign 0.29.0 cannot sign it — such frameworks are now linked, not embedded;
- App Store Connect rejects `limit` on the bundle-ID capabilities relationship;
- the increased-memory-limit capability cannot be enabled through the App Store Connect API (portal only); xless refreshes the profile once and explains the manual step;
- multi-size iOS app-icon sets failed App Store validation (90023) — they are now compiled from the 1024 marketing icon.

Known gaps: `docs/research/parity-known-gaps.md` (Tauri iOS).
