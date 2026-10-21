# xless

xless builds iOS and macOS apps on Linux, with no Mac. It compiles a Swift package, a React Native (Expo) app, a
Tauri app or a plain Cargo app against Apple's SDK, and can then sign it, package it and upload it to TestFlight. Everything runs in Docker
images that you build once, on your own machine, from the Xcode download Apple gives you.

## What you need

- A Linux machine, x86_64 or arm64.
- [Docker Engine](https://docs.docker.com/engine/install/) with the buildx plugin, usable without `sudo`
  (your user is in the `docker` group).
- Free disk space, per Xcode version and architecture: about 17 GB in your home directory's cache (`~/.cache`) while
  the SDK is taken out of the `.xip` (about 3.5 GB of it stays), and about 40 GB where Docker keeps its data
  (`/var/lib/docker` by default) for the images and their build cache, plus a few GB for each app's build caches.
  `xless setup` checks both before it starts.
- Xcode 27.0 or 26.2 from Apple, as the `.xip` file Apple distributes. xless takes Apple's SDK out of it; it never runs
  a program from it. See [Get Xcode](#get-xcode).

You do not need a Mac, and you do not need to unpack the `.xip`.

### Get Xcode

1. Open <https://developer.apple.com/download/all/> and sign in with your Apple ID. A free Apple ID is enough.
2. Search for the Xcode version and download its `.xip`. Where Apple offers a "Universal" and an "Apple silicon"
   file, take the Universal one (for 26.2, xless also accepts the Apple silicon file).

   | Xcode | File to download |
   |---|---|
   | 27.0 (build 27A266a) | `Xcode_27.xip` |
   | 26.2 (build 17C52) | `Xcode_26.2_Universal.xip` |

3. Keep the file where your browser saved it. The commands below assume `~/Downloads`.

xless recognises the file by its content, not by its name, and refuses any other Xcode version
([what to do then](docs/troubleshooting.md#xless-setup)).
[docs/apple-requirements.md](docs/apple-requirements.md) lists everything xless uses from Apple, and why.

## Install

```sh
curl -fsSL https://github.com/fmsouza/xless/releases/latest/download/install.sh | sh
```

This puts `xless` in `~/.local/bin` and its support files in `~/.local/share/xless`, after checking the download
against the release's checksums. It needs no `sudo`. If it says that `~/.local/bin` is not on `PATH` in this shell,
open a new terminal (many Linux systems add `~/.local/bin` at login once it exists) or run the `export` line it
prints. If a new terminal still cannot find `xless`, add that line to your shell's startup file. Then check:

```sh
xless --version
```

Each release asset also carries a signed build provenance attestation: proof that the release workflow of
`fmsouza/xless` built it, from which commit. To check a download yourself with the [GitHub CLI](https://cli.github.com/)
(signed in with `gh auth login`):

```sh
gh attestation verify xless-<version>-linux-<arch>.tar.gz -R fmsouza/xless
```

`SHA256SUMS` and `install.sh` are attested too. The installer itself checks the checksum only; it does not need `gh`.

## Build the images

```sh
xless setup --xcode ~/Downloads/Xcode_27.xip
```

This builds four Docker images on your machine: `xless-base`, `xless` (with Apple's SDK), `xless-tauri` (Tauri and
plain Cargo apps) and `xless-rn`. It first checks Docker and your free disk space, then prints each step with a rough time. The whole run
took about 13 minutes on an 8-core machine with a fast network; it depends on your CPU and network, and can take an
hour on a slow one. You do this once per Xcode version. When it finishes it prints the next command to run. To see the
plan and the disk space it asks for without running anything, add `--dry-run`.

`docker images` then lists each image under several tags that name the same image: `:local-<arch>-xcode<version>`,
`:local-<arch>-xcode<version>-<build>` and, for Xcode 27.0, `:local-<arch>`.

For Xcode 26.2 use `xless setup --xcode ~/Downloads/Xcode_26.2_Universal.xip`. The images never leave your machine:
they contain Apple's SDK, so do not push them to a public registry.

## Build the sample app

The install includes a small iOS app, HelloShip. Copy it and build it:

```sh
cp -r ~/.local/share/xless/samples/HelloShip ~/HelloShip
xless docker ~/HelloShip --build-number 1 --to finalize
```

If you built the images from Xcode 26.2 only, run this between the two commands, so that the sample uses that Xcode:

```sh
echo 'xcode: "26.2"' >> ~/HelloShip/xless.yml
```

Once the images exist, this takes under a minute. The build ends with `stopped after finalize (--to), nothing
delivered`. The finished app is `~/HelloShip/.xless/build/ios/final/HelloShip.app`: an unsigned iOS app for arm64
devices. Paths in the output that start with `/work` are inside the build container, where `/work` is your project
directory: `/work/.xless/build/ios/final/HelloShip.app` is that same app. No Apple account is needed for this step.

The build runs as root inside the container, so the files it creates in `~/HelloShip` (`.xless`, `.build`, `.bsp`,
`xtool` and `xtool.yml`) belong to root. Remove the copy with `sudo rm -rf ~/HelloShip`.

## Next

- [Sign the app and upload it to TestFlight](docs/signing-and-testflight.md): you need an Apple Developer Program
  membership for this.
- [React Native and Expo apps](docs/react-native.md)
- [Tauri v2 apps](docs/tauri.md), for iOS and macOS
- [Plain Cargo apps](docs/cargo.md) (winit, egui…), for iOS and macOS
- [Troubleshooting](docs/troubleshooting.md)
- [Uninstall xless and free its disk space](docs/uninstall.md): `xless clean`
- [All documentation](docs/README.md), including how xless works and how to contribute

## Apple software

xless contains and distributes no Apple software: no Xcode, no SDKs, no Apple tools. You obtain Xcode from Apple
yourself and are responsible for complying with its license terms. Images that contain an SDK you exported are built
locally and are not meant to be published.

## Licence

xless is released under the [MIT licence](LICENSE). Each release also carries the licence notices of the third-party
code built into the `xless` binary, in `share/xless/licenses/`.
