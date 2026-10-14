import Testing
import Foundation
@testable import XlessCore

@Test func readsEnvAndTrimsIdentifiers() throws {
    let s = Secrets(env: ["ASC_KEY_ID": " ABC123\r\n"])
    #expect(try s.identifier("ASC_KEY_ID", stage: .upload) == "ABC123")
}

@Test func readsFileVariant() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n".write(to: url, atomically: true, encoding: .utf8)
    let s = Secrets(env: ["ASC_KEY_P8_FILE": url.path])
    #expect(try s.required("ASC_KEY_P8", stage: .upload).contains("BEGIN PRIVATE KEY"))
}

@Test func missingSecretNamesBothVariables() {
    let s = Secrets(env: [:])
    do { _ = try s.required("XLESS_DIST_KEY", stage: .sign); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.description.contains("XLESS_DIST_KEY_FILE")) }
    catch { Issue.record("\(error)") }
}

@Test func emptyValueIsMissing() throws {
    #expect(try Secrets(env: ["X": ""]).optional("X") == nil)
}
