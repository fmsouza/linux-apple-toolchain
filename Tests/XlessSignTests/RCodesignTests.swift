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
