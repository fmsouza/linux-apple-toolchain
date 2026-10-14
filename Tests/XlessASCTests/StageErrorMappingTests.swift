import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import XlessASC
@testable import XlessCore

private func mapped(_ stage: Stage, _ op: () async throws -> Void) async -> XlessError? {
    do { try await withStage(stage, op); return nil } catch { return error as? XlessError }
}

@Test func raw401FromClientBecomesStageErrorWithCredentialsHint() async {
    let t = MockTransport([(401, #"{"errors":[{"status":"401","code":"NOT_AUTHORIZED","title":"Authentication credentials are missing or invalid."}]}"#)])
    let client = ASCClient(credentials: testCreds, transport: t, sleep: { _ in })
    let e = await mapped(.sign) { let _: ASCDocument<[ASCRef]> = try await client.get("/v1/certificates") }
    #expect(e?.stage == .sign)
    #expect(e?.description.hasPrefix("[sign] App Store Connect HTTP 401") == true)
    #expect(e?.cause.contains("NOT_AUTHORIZED") == true)
    #expect(e?.fix.contains("ASC_KEY_ID") == true && e?.fix.contains("ASC_KEY_P8") == true)
}

@Test func raw403BecomesRoleHint() async {
    let e = await mapped(.upload) { throw ASCError(status: 403, items: [.init(status: "403", code: "FORBIDDEN_ERROR", title: nil, detail: nil)]) }
    #expect(e?.stage == .upload)
    #expect(e?.fix.contains("Admin") == true)
}

@Test func otherASCErrorKeepsTextAndKnownIssue() async {
    let e = await mapped(.upload) {
        throw ASCError(status: 409, items: [.init(status: "409", code: "ENTITY_ERROR", title: nil, detail: "The bundle version must be higher than the previously uploaded version.")])
    }
    #expect(e?.cause.contains("HTTP 409") == true)
    #expect(e?.fix.contains("build number") == true)
}

@Test func urlErrorBecomesNetworkError() async {
    let e = await mapped(.sign) { throw URLError(.notConnectedToInternet) }
    #expect(e?.stage == .sign)
    #expect(e?.cause.contains("network") == true, "\(String(describing: e))")
}

@Test func uploaderWrapsUndecodableResponse() async {
    let t = MockTransport([(200, "not json")])
    let up = BuildUploader(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }), sleep: { _ in })
    do { _ = try await up.upload(ipa: tempIPA(1), bundleID: "a.b", version: "1", build: "1", platform: .ios); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .upload); #expect(e.cause.contains("looking up the app record")) }
    catch { Issue.record("not an XlessError: \(error)") }
}
