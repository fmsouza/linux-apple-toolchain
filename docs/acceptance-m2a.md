# Milestone 2a acceptance (2026-10-15) — launch-screen storyboard compiler

| Criterion (spec §7) | Result |
|---|---|
| All corpus cases byte-identical to Xcode 27.0 ibtool on Linux and macOS | PASS — 277 storyboards; every case byte-identical or refused with a test (`swift test`, `make test-linux`) |
| A real Tauri app's `LaunchScreen.storyboard` compiles byte-identical | PASS — corpus case `real-tauri-app` (all flag sets) |
| Sample with a launch storyboard built on Linux → TestFlight VALID → launch screen shows on device | PASS — `samples/HelloShipLaunch` built in the linux/arm64 image, uploaded and delivered by `make testflight`; installed from TestFlight on an iPhone; launch screen shows logo and label |

Additional evidence:
- `make ib-parity`: goldens regenerate with no drift; the sample's `.storyboardc` is byte-identical to Xcode's; iOS 27 simulator screenshots differ by 0 pixels.
- Random differential runs against ibtool (committed `scripts/ib-corpus/differential.py`, several seeds, ~1,500 storyboards incl. `--colors`): 0 mismatches; refusals only for documented open questions.
- `make testflight` delivered the build to an automatically-created internal TestFlight group with "What to Test" set, in one command.

Inputs the compiler refuses (by design — never emits bytes it cannot prove; see `docs/research/nib-encoding.md#open-questions`):
- colors in displayP3 / calibratedRGB / calibratedWhite;
- gray components within 1e-6 of 0 or 1;
- custom fonts that ship with macOS/iOS (only fonts not installed on the compiling machine are supported);
- SF Symbols other than the 38 proven names;
- constraint ordering ties that differ only in their second item, and ties between owner-written and non-owner-written constraints;
- constraints mixing leading/trailing with left/right;
- more than 107 distinct keys, nesting deeper than 32 levels, input over 4 MiB.
