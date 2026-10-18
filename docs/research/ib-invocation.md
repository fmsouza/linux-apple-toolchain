# Xcode's ibtool invocation (Xcode 27.0, 27A266a; ibtool 27.0, bundle-version 25098)

Measured by building a throwaway XcodeGen project (iOS app, `LaunchScreen.storyboard` from Xcode's
"iOS App Base" template, `xcodebuild -configuration Release -destination generic/platform=iOS`, `CODE_SIGNING_ALLOWED=NO`)
and reading the build log. No Apple binary was disassembled; every claim below comes from running ibtool on our own inputs.
The path in Xcode 27 is `Templates/Project Templates/MultiPlatform/Application/iOS App Base.xctemplate/LaunchScreen.storyboard` (unchanged from the brief).

## Command lines (paths replaced)

Two build steps run, in this order.

### CompileStoryboard

```
ibtool --errors --warnings --notices --module <ProductModule>
  --output-partial-info-plist <build>/LaunchScreen-SBPartialInfo.plist
  --auto-activate-custom-fonts
  --target-device iphone [--target-device ipad]
  --minimum-deployment-target <N.N>
  --output-format human-readable-text
  <in>.storyboard
  --compilation-directory <build>
```
Output: `<build>/LaunchScreen.storyboardc/` (named after the storyboard; `--compilation-directory` replaces `--compile <out>`).
`ibtool` here is `/Applications/Xcode.app/Contents/Developer/usr/bin/ibtool`; `xcrun ibtool` runs the same tool.

### LinkStoryboards (yes, Xcode runs a separate link step)

```
ibtool --errors --warnings --notices --module <ProductModule>
  --target-device iphone [--target-device ipad]
  --minimum-deployment-target <N.N>
  --output-format human-readable-text
  --link <out>.app <build>/LaunchScreen.storyboardc
```

### Where the result lands

`<out>.app/LaunchScreen.storyboardc/` at the **bundle root** (not `Base.lproj/`; the project has no localisations).
The product also gets `UILaunchStoryboardName = LaunchScreen` in Info.plist (from the build setting; the partial info plist
that the compile step emits is `<dict/>` for these inputs).

For single storyboards without storyboard references, the link step is a no-op on content: the linked
`.storyboardc` is byte-identical (`diff -r`) to the compile output, both for Xcode's own run and for a manual
`ibtool --link <fresh empty dir> <compiled>` with the same device/target flags. `scripts/ib-golden.sh` still performs the link step so
that the goldens follow Xcode's real pipeline. (Multi-storyboard linking with references is out of scope for 2a and was not measured.)

Contents of the result: `Info.plist` (`UIStoryboardDesignatedEntryPointIdentifier`, `UIStoryboardVersion = 1`,
`UIViewControllerIdentifiersToNibNames`) plus `UIViewController-<id>.nib` and `<id>-view-<id>.nib` (NIBArchive).

## Flags that depend on build settings

| Flag | Source | Effect on output |
|---|---|---|
| `--target-device iphone` / `ipad` | `TARGETED_DEVICE_FAMILY` (`1` -> iphone; `1,2` -> iphone + ipad) | None for the template storyboard and the real-tauri-app storyboard (a real Tauri v2 app's launch screen, copied unchanged): `iphone-16` == `universal-16` byte for byte. (Expected to matter once device-specific variations exist.) |
| `--minimum-deployment-target` | `IPHONEOS_DEPLOYMENT_TARGET` | **Changes the view nib** across a threshold between 16.99 and 17.0 (below: identical to 15.0/16.0/16.4/16.5/16.99; at and above 17.0: identical to 18.0/26.0/27.0). 4 byte-pairs differ in `<id>-view-<id>.nib` (1-based offsets 916, 917, 924, 925, 936, 937, 944, 945); VC nib and Info.plist are unchanged. Omitting the flag gives the >=17 variant. The real-tauri-app storyboard shows the same split (goldens `universal-16` vs `universal-17` differ). |
| `--module <name>` | `PRODUCT_MODULE_NAME` | None for these inputs (no custom classes). May matter for `customClass` once supported. |
| `--auto-activate-custom-fonts` | always passed | None for these inputs. |

Xcode 27.0 rejects `IPHONEOS_DEPLOYMENT_TARGET = 13.0` ("range of supported deployment target versions is 15.0 to 27.0.x"),
so the brief's `universal-13` flag set cannot occur in a real Xcode 27 build; standalone ibtool accepts 13.0 and produces the same
bytes as 15.0/16.0. See Deviations in the task report: the corpus uses `universal-15` instead, plus `universal-17` to cover the nib difference above.

## Diagnostic-only flags (no effect on output)

`--errors --warnings --notices --output-format human-readable-text` select diagnostic reporting only;
`--output-partial-info-plist <path>` writes a side file only (`<dict/>` here), and `--compilation-directory` / `--compile` only
choose the output location. For both seed storyboards, compiling with each of these (individually and all together, plus
`--module IBProbe` and `--auto-activate-custom-fonts`) and without them produced output trees with `diff -r` identical contents.
Re-running the golden generator twice also gives identical trees (deterministic), and the goldens are byte-identical
(`diff -r`) to what Xcode put in the .app for `universal-16`, `iphone-16`, `universal-15` (template) and `universal-16` (real-tauri-app storyboard).

## Goldens are pinned to `--module IBProbe`

`scripts/ib-golden.sh` always passes `--module IBProbe` (the module name used by the probe project that produced the
Xcode reference output), and the Swift compiler under test must use the same module name when it is compared with the goldens.
The module name did not change the output for either seed storyboard (no custom classes), but it may for `customClass`
references; custom classes are out of scope for milestone 2a.

`--compile <dir>.storyboardc` (used by the script) versus Xcode's `--compilation-directory <dir>` (output written to
`<dir>/<name>.storyboardc`) was verified to be output-neutral: compiling both seed storyboards with the full Xcode flag set
both ways gave `diff -r` identical trees.

## Behaviours worth knowing

- `ibtool --version` prints an XML plist (`com.apple.ibtool.version` -> `short-bundle-version` 27.0, `bundle-version` 25098); there is no human-readable first line. `IBTOOL_VERSION` line 1 is `ibtool 27.0 (25098)`, followed by the `xcodebuild -version` lines.
- ibtool exits 0 on success and non-zero on error, and with `--errors --warnings --notices` it prints nothing for clean input, so `ib-golden.sh` treats any output or a non-zero exit as failure.
- `ib-golden.sh` writes `Tests/IBCorpus/golden/<build>/` for the build `xcodebuild -version` reports under the caller's `DEVELOPER_DIR`, and refuses to run when the live ibtool differs from that directory's `IBTOOL_VERSION` (override with `--accept-new-ibtool`).
- Xcode prints no ibtool warnings for either seed storyboard.
