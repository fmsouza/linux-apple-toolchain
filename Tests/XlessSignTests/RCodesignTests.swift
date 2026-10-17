import Testing
import Foundation
@testable import XlessSign
@testable import XlessCore

private func u(_ p: String) -> URL { URL(fileURLWithPath: p) }

@Test func appStoreSigningDisablesTimestamp() {
    let a = RCodesign.signArguments(bundle: u("/b/X.app"), keyPEM: u("/k.pem"), certPEM: u("/c.pem"), entitlements: u("/e.plist"), distribution: .appStore)
    #expect(a.first == "sign")
    #expect(a.contains("--pem-file") && a.contains("/k.pem") && a.contains("/c.pem"))
    #expect(a.contains("--entitlements-xml-file") && a.contains("/e.plist"))
    #expect(zip(a, a.dropFirst()).contains { $0 == ("--timestamp-url", "none") })
    #expect(!a.contains("--for-notarization"))
    #expect(a.last == "/b/X.app")
}

@Test func developerIDUsesHardenedRuntimeAndTimestamp() {
    let a = RCodesign.signArguments(bundle: u("/b/X.app"), keyPEM: u("/k.pem"), certPEM: u("/c.pem"), entitlements: u("/e.plist"), distribution: .developerID)
    #expect(a.contains("--for-notarization"))
    #expect(zip(a, a.dropFirst()).contains { $0 == ("--code-signature-flags", "runtime") })
    #expect(!a.contains("none"))
}

@Test func notarizeArguments() {
    #expect(RCodesign.notarizeArguments(bundle: u("/X.app"), apiKeyJSON: u("/k.json"))
            == ["notary-submit", "--api-key-file", "/k.json", "--max-wait-seconds", "3600", "--staple", "/X.app"])
}

@Test func encodeKeyArguments() {
    #expect(RCodesign.encodeKeyArguments(issuerID: "I", keyID: "K", p8: u("/a.p8"), out: u("/o.json"))
            == ["encode-app-store-connect-api-key", "-o", "/o.json", "I", "K", "/a.p8"])
}

/// rcodesign applies an unscoped --code-signature-flags to the main executable only; every other Mach-O that must carry
/// the hardened runtime is named with a path-scoped flag.
@Test func developerIDScopesTheRuntimeFlagToNestedMachOs() {
    let a = RCodesign.signArguments(bundle: u("/b/X.app"), keyPEM: u("/k.pem"), certPEM: u("/c.pem"), entitlements: u("/e.plist"), distribution: .developerID,
                                    runtimePaths: ["Contents/Resources/lib.dylib", "Contents/Frameworks/libx.dylib"])
    #expect(zip(a, a.dropFirst()).contains { $0 == ("--code-signature-flags", "Contents/Resources/lib.dylib:runtime") })
    #expect(zip(a, a.dropFirst()).contains { $0 == ("--code-signature-flags", "Contents/Frameworks/libx.dylib:runtime") })
    #expect(a.last == "/b/X.app")
    let store = RCodesign.signArguments(bundle: u("/b/X.app"), keyPEM: u("/k.pem"), certPEM: u("/c.pem"), entitlements: u("/e.plist"), distribution: .appStore,
                                        runtimePaths: ["Contents/Resources/lib.dylib"])
    #expect(!store.contains { $0.hasSuffix(":runtime") })
}

/// The Mach-O images of a macOS bundle that get a path-scoped runtime flag: all but the main executable.
@Test func findsHardenedRuntimePaths() throws {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("loose-\(UUID())/X.app")
    let image = Data([0xcf, 0xfa, 0xed, 0xfe]) + Data(count: 28)
    for (path, data) in [("Contents/MacOS/X", image), ("Contents/Resources/lib/a.dylib", image), ("Contents/Resources/notes.txt", Data("t".utf8)),
                         ("Contents/Frameworks/libx.dylib", image), ("Contents/Frameworks/Y.framework/Versions/A/Y", image),
                         ("Contents/Resources/static.a", Data("!<arch>\n".utf8))] {
        let url = app.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    // Loose Mach-Os and the binaries inside nested bundles, by their real path (not via symlinks); no non-Mach-O files.
    let resources = app.appendingPathComponent("Contents/Resources/Assets.bundle/Contents/Resources/a.txt")
    try FileManager.default.createDirectory(at: resources.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("t".utf8).write(to: resources)
    try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("Contents/Frameworks/Y.framework/Y").path, withDestinationPath: "Versions/A/Y")
    #expect(RCodesign.hardenedRuntimePaths(in: app, mainExecutable: "Contents/MacOS/X")
            == ["Contents/Frameworks/Y.framework/Versions/A/Y", "Contents/Frameworks/libx.dylib", "Contents/Resources/lib/a.dylib"])
}
