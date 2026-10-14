include versions.env
export

.PHONY: test test-linux
test:
	swift test

test-linux:
	docker run --rm -v "$(CURDIR)":/src -w /src swift:$(SWIFT_VERSION)-jammy \
	  bash -c 'apt-get update -qq && apt-get install -y -qq zip unzip >/dev/null && swift test --scratch-path /tmp/.build'

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

.PHONY: parity
parity:
	scripts/parity.sh
