import Testing
@testable import XlessSDK

@Test func cleanTakesEveryLocalTagOfTheFourImagesOnly() {
    let listing = """
    xless-base:local-arm64-xcode27.0-27A266a
    xless:local-arm64
    xless:local-arm64-xcode26.2
    xless-tauri:local-amd64-xcode27.0
    xless-rn:local-arm64
    xless-rn:<none>
    registry.example.com/xless:xcode27.0-27A266a-v0.1.0
    xless-other:local
    swift:6.4.0-jammy
    alpine:latest
    xless:local-arm64

    """
    #expect(CleanPlan.images(fromListing: listing) == [
        "xless-base:local-arm64-xcode27.0-27A266a", "xless:local-arm64", "xless:local-arm64-xcode26.2",
        "xless-tauri:local-amd64-xcode27.0", "xless-rn:local-arm64",
    ])
    #expect(CleanPlan.images(fromListing: "") == [])
}

@Test func cleanTakesXlessVolumesOnly() {
    let listing = "xless-rustup\nxless-cargo\nxless-rn-work-overlay-1a2b3c4d\nxless-rn-work-\nxless-corepack\nxless-bundle\n"
        + "xless-cocoapods-home\nxless-cocoapods-cache\nmy-db\nxless-rustup-backup\n"
    #expect(CleanPlan.volumes(fromListing: listing) == [
        "xless-rustup", "xless-cargo", "xless-rn-work-overlay-1a2b3c4d", "xless-corepack", "xless-bundle",
        "xless-cocoapods-home", "xless-cocoapods-cache",
    ])
}
