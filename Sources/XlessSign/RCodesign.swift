import Foundation
import XlessCore

public enum RCodesign {
    public static func signArguments(bundle: URL, keyPEM: URL, certPEM: URL, entitlements: URL, distribution: Distribution) -> [String] {
        var a = ["sign", "--pem-file", keyPEM.path, "--pem-file", certPEM.path, "--entitlements-xml-file", entitlements.path]
        switch distribution {
        case .appStore:
            a += ["--timestamp-url", "none"]   // ITMS-90135: App Store builds must not carry a secure timestamp
        case .developerID:
            a += ["--code-signature-flags", "runtime", "--for-notarization"]
        }
        return a + [bundle.path]
    }

    /// rcodesign 0.29.0 waits 600 s by default (`notary-submit --help`); notarization queues can take longer.
    public static func notarizeArguments(bundle: URL, apiKeyJSON: URL) -> [String] {
        ["notary-submit", "--api-key-file", apiKeyJSON.path, "--max-wait-seconds", "3600", "--staple", bundle.path]
    }

    public static func encodeKeyArguments(issuerID: String, keyID: String, p8: URL, out: URL) -> [String] {
        ["encode-app-store-connect-api-key", "-o", out.path, issuerID, keyID, p8.path]
    }
}
