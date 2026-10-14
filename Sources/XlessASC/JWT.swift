import Crypto
import Foundation
import XlessCore

public struct ASCCredentials: Sendable {
    public var keyID: String
    public var issuerID: String
    public var privateKeyPEM: String

    public init(keyID: String, issuerID: String, privateKeyPEM: String) {
        self.keyID = keyID; self.issuerID = issuerID; self.privateKeyPEM = privateKeyPEM
    }

    public static func fromSecrets(_ s: Secrets, stage: Stage) throws -> ASCCredentials {
        ASCCredentials(keyID: try s.identifier("ASC_KEY_ID", stage: stage),
                       issuerID: try s.identifier("ASC_ISSUER_ID", stage: stage),
                       privateKeyPEM: try s.required("ASC_KEY_P8", stage: stage))
    }
}

public enum JWT {
    static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// ES256 token for the App Store Connect API (15-minute lifetime, leaving clock-skew margin under Apple's 20-minute maximum).
    public static func appStoreConnect(_ c: ASCCredentials, now: Date = Date()) throws -> String {
        let key: P256.Signing.PrivateKey
        do { key = try P256.Signing.PrivateKey(pemRepresentation: PEM.normalize(c.privateKeyPEM)) } catch {
            throw XlessError(.config, "ASC_KEY_P8 is not a valid App Store Connect .p8 key", fix: "set ASC_KEY_P8 to the full contents of AuthKey_<id>.p8")
        }
        let iat = Int(now.timeIntervalSince1970)
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": c.keyID, "typ": "JWT"], options: [.sortedKeys])
        let claims = try JSONSerialization.data(withJSONObject: ["iss": c.issuerID, "iat": iat, "exp": iat + 900, "aud": "appstoreconnect-v1"], options: [.sortedKeys])
        let signingInput = "\(b64url(header)).\(b64url(claims))"
        let sig = try key.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(b64url(sig.rawRepresentation))"
    }
}
