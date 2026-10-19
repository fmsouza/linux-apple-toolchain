# One-time Apple setup

Do these in order. Keep every secret in your CI secret store and a password manager; never commit them. (`.gitignore` already excludes `*.p8` and `*.pem`.)

## 1. App Store Connect API key

App Store Connect → Users and Access → Integrations → App Store Connect API → generate a key with the **Admin** role. Download the `.p8` (Apple offers it once).

Store three secrets:

- `ASC_KEY_ID`: the key ID shown in the list.
- `ASC_ISSUER_ID`: the issuer ID shown at the top of the page.
- `ASC_KEY_P8`: the full contents of the `.p8` file.

xless also accepts `ASC_KEY_P8_FILE=/path/to/AuthKey.p8` (and `_FILE` for every other secret).

## 2. Apple Distribution key (iOS)

```sh
xless sign bootstrap --type distribution --out dist-key.pem
```

Store the contents of `dist-key.pem` as `XLESS_DIST_KEY`, then delete the file.

## 3. Developer ID Application key (macOS only)

```sh
xless sign bootstrap --type developer-id --out devid-key.pem
```

Store it as `XLESS_DEVID_KEY`, then delete the file.

If App Store Connect answers 403 (creating Developer ID certificates can require the Account Holder), use `--csr-only` instead:

```sh
xless sign bootstrap --type developer-id --out devid-key.pem --csr-only
```

Then go to developer.apple.com → Certificates, IDs & Profiles → Certificates → + → Developer ID Application, upload `devid-key.pem.csr`, and finish. Store `devid-key.pem` as `XLESS_DEVID_KEY`.

## How `sign bootstrap` behaves

App Store Connect creates a certificate from a CSR but never returns the private key, so xless generates an RSA-2048 key locally.

- The key is written to `--out` (mode 0600, never overwriting an existing file) before any network call, so a write failure cannot cost you a certificate.
- It refuses to continue if the team already has certificates of that kind, because their keys cannot be downloaded. Reuse the key you stored, or pass `--allow-new` to create another.
- It also refuses if the team is at Apple's per-team limit (3 Distribution, 5 Developer ID). These limits are unconfirmed against Apple's documentation; revoke unused certificates at developer.apple.com if xless reports the cap.
- Certificate creation is never retried. If the request fails in a way that may have succeeded (anything but a definite 4xx refusal: transport error, 429, 5xx, an unreadable response, cancellation), xless keeps the key file and tells you to check developer.apple.com → Certificates before retrying with `--allow-new`. On definite failures the unused key file is removed.
- A normal `ship` run later finds the certificate whose public key matches your stored key, registers the bundle ID if needed (as `UNIVERSAL`, so iOS and macOS share it), and finds or creates a matching provisioning profile.

## 4. Bundle ID (before the app record)

App Store Connect's New App dialog only offers bundle IDs that are already registered, so register the `bundleID` from `xless.yml` first. Either:

- by hand: developer.apple.com → Certificates, IDs & Profiles → Identifiers → + → App IDs → App, with the `bundleID` as an explicit Bundle ID; or
- with xless, once the image or native install from steps 6–7 is ready: run `xless ship --platform ios` once. The `sign` stage registers the bundle ID (as a universal identifier, usable by both the iOS and the macOS build), and the run then stops at `upload` with "no app record". After step 5, finish with `xless upload --platform ios`, without a build-number override (or with the same one).

## 5. App record

App Store Connect → My Apps → + → New App, choosing the bundle ID registered in step 4 (for iOS, `platforms.ios.bundleID` if you override it). The API cannot create app records; `xless upload` fails until this exists. macOS Developer ID builds do not need an app record.

## 6. Images (Mac, once per Xcode release)

```sh
cp registry.env.example registry.env     # edit: XLESS_REGISTRY, then XLESS_REGISTRY_PRIVATE=true after verifying it is private
make base-push sdk-export sdk-push
```

Details, including making Xcode visible to the Docker VM, are in [README.md](README.md#building-the-images-on-the-mac).

## 7. Linux

Either run in Docker:

```sh
docker run --rm -v "$PWD":/work -w /work -e ASC_KEY_ID -e ASC_ISSUER_ID -e ASC_KEY_P8 -e XLESS_DIST_KEY \
  <image> xless ship --platform ios
```

or install natively (`scripts/install-native.sh`, then `xless sdk install --image <image>`); see [README.md](README.md#native-install).
