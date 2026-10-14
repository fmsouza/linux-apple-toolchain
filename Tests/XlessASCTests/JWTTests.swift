import Testing
import Foundation
import Crypto
import XlessCore
@testable import XlessASC

func b64urlDecode(_ s: Substring) -> Data {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t += "=" }
    return Data(base64Encoded: t)!
}

@Test func jwtHasExpectedClaimsAndVerifies() throws {
    let key = P256.Signing.PrivateKey()
    let creds = ASCCredentials(keyID: "KEY123", issuerID: "iss-1", privateKeyPEM: "\n" + key.pemRepresentation + "\n")
    let token = try JWT.appStoreConnect(creds, now: Date(timeIntervalSince1970: 1_000_000))
    let parts = token.split(separator: ".")
    #expect(parts.count == 3)
    let header = try JSONSerialization.jsonObject(with: b64urlDecode(parts[0])) as! [String: Any]
    let claims = try JSONSerialization.jsonObject(with: b64urlDecode(parts[1])) as! [String: Any]
    #expect(header["typ"] as? String == "JWT")
    #expect(claims["iat"] as? Int == 1_000_000)
    #expect(header["alg"] as? String == "ES256" && header["kid"] as? String == "KEY123")
    #expect(claims["iss"] as? String == "iss-1" && claims["aud"] as? String == "appstoreconnect-v1")
    #expect(claims["exp"] as? Int == 1_000_000 + 900)
    let sig = try P256.Signing.ECDSASignature(rawRepresentation: b64urlDecode(parts[2]))
    #expect(key.publicKey.isValidSignature(sig, for: Data("\(parts[0]).\(parts[1])".utf8)))
}

@Test func badKeyIsConfigError() {
    let creds = ASCCredentials(keyID: "K", issuerID: "I", privateKeyPEM: "nope")
    do { _ = try JWT.appStoreConnect(creds); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .config)
        #expect(!e.description.contains("nope"))
    } catch { Issue.record("wrong error \(error)") }
}

@Test(arguments: ["\r\n", "\\n"])
func jwtAcceptsMangledP8(newline: String) throws {
    let key = P256.Signing.PrivateKey()
    let mangled = key.pemRepresentation.replacingOccurrences(of: "\n", with: newline) + newline
    let token = try JWT.appStoreConnect(ASCCredentials(keyID: "K", issuerID: "I", privateKeyPEM: mangled))
    let parts = token.split(separator: ".")
    let sig = try P256.Signing.ECDSASignature(rawRepresentation: b64urlDecode(parts[2]))
    #expect(key.publicKey.isValidSignature(sig, for: Data("\(parts[0]).\(parts[1])".utf8)))
}
