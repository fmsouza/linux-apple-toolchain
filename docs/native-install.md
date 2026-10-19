# Native install (without Docker for builds)

The usual way to run xless is in the Docker images that `xless setup` builds ([README](../README.md)). On a
Debian or Ubuntu machine (arm64 or x86_64) you can instead install the toolset directly and run `xless ship` without
Docker. This path is for `xless.yml` projects; native Tauri and React Native builds need much more of what the images
add and are untested ([tauri.md](tauri.md#shipping), [react-native.md](react-native.md#shipping-three-containers)).

## 1. The toolset

The installer is in the source repository, not in the release:

```sh
git clone https://github.com/fmsouza/linux-apple-toolchain.git
cd linux-apple-toolchain
scripts/install-native.sh                  # or: scripts/install-native.sh --prefix /usr/local
```

It installs Swift 6.4.0 (through swiftly, if that Swift is not already there), xtool and rcodesign (both checked
against the sha256 pins in `versions.env`), then builds `xless` from the checkout and installs it into
`<prefix>/bin` (default `/usr/local`). It uses `sudo` when not run as root and is safe to re-run. swiftly itself is
downloaded without a pin or a signature check.

xless built this way finds its data files (`versions.env`, the Dockerfiles) only through `XLESS_SHARE`. `xless ship`
does not need them; `xless setup`, `xless docker` and `xless sdk meta` do: run them with `XLESS_SHARE=<the checkout>`,
or use the release install for those.

## 2. The SDK

A native install needs the Darwin SDK and its metadata on the machine. Both come out of the images or the cache that
`xless setup` made (Docker is needed once, for that):

```sh
# from the cache of `xless setup` (this machine's architecture: arm64 or amd64)
xless sdk install --xtoolsdk ~/.cache/xless/sdk/xcode27.0-27A266a/arm64/darwin.xtoolsdk \
                  --meta ~/.cache/xless/sdk/xcode27.0-27A266a/toolchain-meta.json
# or copied out of the local image
xless sdk install --image xless:local-arm64
```

Use `amd64` in place of `arm64` on an x86_64 machine, and `xcode26.2-17C52` for Xcode 26.2. The cache is under
`$XDG_CACHE_HOME/xless` when `XDG_CACHE_HOME` is set.

The SDK goes to the xtool config directory (`$XDG_CONFIG_HOME/swiftpm/swift-sdks/`, else `~/.swiftpm/swift-sdks/`) and
the metadata to `XLESS_TOOLCHAIN_META`, else `$XDG_CONFIG_HOME/xless/toolchain-meta.json`
(`~/.config/xless/toolchain-meta.json` when `XDG_CONFIG_HOME` is unset). Installation is staged and swapped in only on
success, so a failure leaves any existing install untouched. The `--image` form copies out of the image with
`docker create` and `docker cp`; an image from a private registry ([maintainers.md](maintainers.md#private-registries))
works too, after `docker login`.

## 3. Build

From the project directory:

```sh
xless ship --platform ios --to finalize
```

Leave out `--to finalize` to sign and upload as well ([signing-and-testflight.md](signing-and-testflight.md)).
`XLESS_USE_DOCKER=0 xless docker <project-dir>` runs the same script as with the images, natively.

A native install compiles app code with the `swift` on `PATH` (6.4), which is Xcode 27.0's Swift. The images also
carry the Swift that Xcode 26.2 ships (6.2.3) and this installer does not, so a project that pins an Xcode with
`xcode:` is refused natively: build it in Docker.
