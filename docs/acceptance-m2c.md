# Milestone 2c acceptance (2026-10-16) — Tauri v2 macOS on Linux

| Criterion (spec §6) | Result |
|---|---|
| 1. `samples/HelloTauri` macOS builds universal on Linux and matches the Mac reference | PASS — `scripts/test-tauri-linux.sh --platform macos` (linux/arm64 image): per-architecture linked libraries, platform, minimum OS and rpaths match `samples/HelloTauri/reference/macos/reference.json`; unsigned DMG listing matches `dmg.json`; remaining gaps in `samples/HelloTauri/reference/macos/allowed-gaps.txt` |
| 2. A real Tauri v2 app builds universal on Linux through an overlay, from a work copy, leaving its checkout untouched | PASS — private acceptance app built for aarch64 + x86_64 in the linux/arm64 image; checkout `git status --porcelain --ignored` and a size/mtime listing of every file identical before and after |
| 3. DMG is Developer ID-signed, notarized and stapled; Gatekeeper accepts it after a quarantined download | PASS — `make dmg CONFIG=<overlay>`: notarization Accepted, ticket stapled; `spctl` accepts the DMG and the drag-installed app (Notarized Developer ID); `stapler validate` OK; `codesign --verify --deep --strict` OK; `lipo -archs` x86_64 arm64; macOS 27 `dyld_info -validate_only` OK for both slices |
| 4. Smoke test on a Mac | PASS — installs from the DMG, launches, opens folders, edits RAW images, ML features run, file association works (user-confirmed) |

Notable behaviour (documented in `docs/research/parity-known-gaps.md`, Tauri macOS):
- runtime libraries that a build script stages per architecture are merged into universal binaries and signed with the hardened runtime (the reference `tauri build --target universal-apple-darwin` ships only the last-built architecture);
- executables are stripped at link time (`-Wl,-x`) because macOS 27 rejects the symbol tables that post-link stripping leaves misaligned;
- the DMG uses Finder's default layout; static-archive frameworks are linked, not embedded.
