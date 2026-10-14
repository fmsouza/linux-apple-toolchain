# Milestone 1 acceptance (2026-10-14)

Sample: `samples/HelloShip` (SwiftUI, iOS + macOS), Xcode 27.0 (27A266a) SDK.

| Criterion | Result |
|---|---|
| iOS build → TestFlight from the linux/arm64 Docker image | PASS — processing VALID; installed from TestFlight on an iPhone (icon, launch, interaction OK) |
| iOS build → TestFlight from the linux/amd64 Docker image | PASS — processing VALID |
| iOS build → TestFlight from a native `scripts/install.sh` setup on x86_64 Debian 13 | PASS — processing VALID |
| macOS build notarized from Linux, accepted by Gatekeeper | PASS — Developer ID, hardened runtime, notarized + stapled; `spctl` accepts as Notarized Developer ID; launches |
| `scripts/parity.sh` against an Xcode build of the same sample | PASS (allow-listed gaps: `docs/research/parity-known-gaps.md`) |
| Example GitHub Actions workflow | Not run (requires a private registry holding the SDK image) |

Issues found only by live App Store Connect runs, both fixed:
- Bundle-ID names may contain only letters, digits and spaces; xless now derives a sanitized name.
- ITMS-90562 (invalid `Assets.car`): upstream AssetKit wrote a BOM index without libBOM's free list and template BITMAPKEYS. AssetKit is vendored under `ThirdParty/AssetKit` with patches; `assetutil --validate-file` and app thinning now pass. `altool --validate-app` does not detect this error.

Not verified: App Review (out of scope).
