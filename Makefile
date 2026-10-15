include versions.env
export

.PHONY: test test-linux
test:
	swift test

test-linux:
	mkdir -p .build-linux
	docker run --rm -v "$(CURDIR)":/src -v "$(CURDIR)/.build-linux":/scratch -w /src swift:$(SWIFT_VERSION)-jammy \
	  bash -c 'apt-get update -qq && apt-get install -y -qq zip unzip rsync git >/dev/null && swift test --scratch-path /scratch'

XLESS_TAG = xcode$(XCODE_VERSION)-$(XCODE_BUILD)-v$(XLESS_VERSION)
BUILD_ARGS = --build-arg SWIFT_VERSION=$(SWIFT_VERSION) --build-arg XTOOL_VERSION=$(XTOOL_VERSION) --build-arg RCODESIGN_VERSION=$(RCODESIGN_VERSION) \
  --build-arg STATIC_SDK_URL=$(STATIC_SDK_URL) --build-arg STATIC_SDK_SHA256=$(STATIC_SDK_SHA256) \
  --build-arg XTOOL_SHA256_AARCH64=$(XTOOL_SHA256_AARCH64) --build-arg XTOOL_SHA256_X86_64=$(XTOOL_SHA256_X86_64) \
  --build-arg RCODESIGN_SHA256_AARCH64=$(RCODESIGN_SHA256_AARCH64) --build-arg RCODESIGN_SHA256_X86_64=$(RCODESIGN_SHA256_X86_64)
XCODE ?= /Applications/Xcode.app

.PHONY: base-local sdk-export sdk-local base-push sdk-push
base-local:
	for a in arm64 amd64; do docker buildx build --platform linux/$$a --load -t xless-base:local-$$a -f docker/Dockerfile.base $(BUILD_ARGS) . || exit 1; done

sdk-export: base-local
	swift run xless sdk export --xcode "$(XCODE)" --out dist/sdk

sdk-local:
	for a in arm64 amd64; do docker buildx build --platform linux/$$a --load -t xless:local-$$a -f docker/Dockerfile.sdk --build-arg BASE=xless-base:local-$$a . || exit 1; done

base-push:
	R=$$(scripts/check-private-registry.sh) && docker buildx build --platform linux/arm64,linux/amd64 --push \
	  -t $$R/xless-base:v$(XLESS_VERSION) -f docker/Dockerfile.base $(BUILD_ARGS) .

sdk-push:
	R=$$(scripts/check-private-registry.sh) && docker buildx build --platform linux/arm64,linux/amd64 --push \
	  -t $$R/xless:$(XLESS_TAG) -f docker/Dockerfile.sdk --build-arg BASE=$$R/xless-base:v$(XLESS_VERSION) .

.PHONY: testflight
# make testflight PROJECT=<dir> | CONFIG=<overlay.yml>: build, sign, upload and deliver an iOS project (or a Tauri app described
# by an overlay, docs/tauri.md) to TestFlight (see scripts/testflight.sh).
testflight:
	@test -n "$(PROJECT)$(CONFIG)" || { echo "usage: make testflight PROJECT=<dir>  or  make testflight CONFIG=<overlay.yml>" >&2; exit 2; }
	@test -z "$(PROJECT)" -o -z "$(CONFIG)" || { echo "give PROJECT or CONFIG, not both" >&2; exit 2; }
	@if test -n "$(CONFIG)"; then scripts/testflight.sh --config "$(CONFIG)"; else scripts/testflight.sh "$(PROJECT)"; fi

.PHONY: test-tauri-linux
# Build samples/HelloTauri on Linux (docker) and compare it with the Mac reference (scripts/test-tauri-linux.sh).
test-tauri-linux:
	scripts/test-tauri-linux.sh

.PHONY: parity ib-parity
parity:
	scripts/parity.sh

ib-parity:
	scripts/ib-parity.sh

TAURI_BUILD_ARGS = --build-arg NODE_VERSION=$(NODE_VERSION) --build-arg NODE_SHA256_ARM64=$(NODE_SHA256_ARM64) --build-arg NODE_SHA256_X64=$(NODE_SHA256_X64) \
  --build-arg RUSTUP_VERSION=$(RUSTUP_VERSION) --build-arg RUSTUP_SHA256_AARCH64=$(RUSTUP_SHA256_AARCH64) --build-arg RUSTUP_SHA256_X86_64=$(RUSTUP_SHA256_X86_64)
.PHONY: tauri-local
tauri-local:
	for a in arm64 amd64; do docker buildx build --platform linux/$$a --load -t xless-tauri:local-$$a -f docker/Dockerfile.tauri --build-arg BASE=xless:local-$$a $(TAURI_BUILD_ARGS) . || exit 1; done

.PHONY: tauri-reference
# make tauri-reference APP=<tauri app root> OUT=<dir> [TAURI_FEATURES=…]: Mac-only black-box reference build of a
# Tauri iOS app with the real Tauri CLI and Xcode (see scripts/tauri-ios-reference.sh). TAURI_BUILD_ARGS (exported
# by this Makefile for the docker build) is not a Tauri variable, so it is kept out of the recorded TAURI_* env.
tauri-reference:
	@test -n "$(APP)" -a -n "$(OUT)" || { echo "usage: make tauri-reference APP=<tauri app root> OUT=<dir>" >&2; exit 2; }
	env -u TAURI_BUILD_ARGS scripts/tauri-ios-reference.sh "$(APP)" "$(OUT)"
