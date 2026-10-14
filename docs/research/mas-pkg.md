# Mac App Store `.pkg` from Linux (not supported in milestone 1)

Status: blocked. macOS apps are shipped as Developer ID signed, notarized and stapled `.app` bundles in a `.zip`. Mac App Store submission needs a signed installer `.pkg`, and no proven path to one exists on Linux.

## What blocks it

1. rcodesign cannot write `.pkg` payloads. It signs bundles and Mach-O files, and can notarize, but it does not create or sign installer packages for this flow.
2. There is no `productbuild` (or `pkgbuild`) on Linux; both ship only with macOS/Xcode.
3. No proven uploads. Nobody has demonstrated a Linux-built `.pkg` accepted by App Store Connect, so even a hand-assembled package is untested against the upload API (`com.apple.pkg` is an accepted UTI for build upload files, see [asc-build-uploads.md](asc-build-uploads.md)).
4. A Mac App Store build also needs a macOS `Assets.car`. AssetKit writes the CAR platform as `ios` (`ExtendedMetadata.defaultPlatform`) and its compiler offers no way to choose another, so xless uses an `.icns` icon on macOS, which is fine for Developer ID only.

## Candidate approaches (future work)

- Assemble the package by hand: a `xar` archive containing `Bom`, `PackageInfo`, `Payload` (cpio+gzip) and `Distribution`, with the BOM built using bomutils (`mkbom`), then sign the package with an "3rd Party Mac Developer Installer" certificate through rcodesign's `.pkg` signing, if it supports it by then.
- Upload the result through the Build Uploads API with `uti` `com.apple.pkg`.
- Add a macOS-capable asset catalog writer (patch AssetKit or use a fork).

Each step needs verification against a real App Store Connect upload before relying on it.
