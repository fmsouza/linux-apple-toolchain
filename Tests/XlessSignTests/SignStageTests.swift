import Testing
import Foundation
@testable import XlessSign
@testable import XlessASC
@testable import XlessCore

/// A project + finalized bundle + mock App Store Connect that returns a matching certificate, the bundle ID
/// and an active profile with `profileEntitlements`.
struct SignFixture {
    let project: URL, input: URL, outputDir: URL, key: SigningKey, transport: MockTransport, config: ProjectConfig

    init(profileEntitlements: [String: Any], userEntitlements: [String: Any] = [:], teamID: String = "ABCDE12345", tail: [(Int, String)]? = nil) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sign-\(UUID())", isDirectory: true)
        project = root.appendingPathComponent("proj", isDirectory: true)
        input = root.appendingPathComponent("final/X.app", isDirectory: true)
        outputDir = root.appendingPathComponent("signed", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try Plist.write(["CFBundleExecutable": "X", "CFBundleIdentifier": "a.b"], to: input.appendingPathComponent("Info.plist"), stage: .sign)
        try Data("not a Mach-O".utf8).write(to: input.appendingPathComponent("X"))
        try Plist.write(userEntitlements, to: project.appendingPathComponent("ios.entitlements"), format: .xml, stage: .sign)
        config = try ProjectConfig.parse(yaml: """
        bundleID: a.b
        teamID: \(teamID)
        version: "1.0"
        build: 1
        platforms:
          ios: { minimumOS: "17.0", product: X, entitlements: ios.entitlements }
        """)
        key = try SigningKey.generate()
        let profile = try fakeProfile(profileEntitlements).base64EncodedString()
        let head: [(Int, String)] = [
            (200, #"{"data":[\#(certJSON(id: "C1", der: try selfSigned(key)))]}"#),
            (200, #"{"data":[{"type":"bundleIds","id":"B1","attributes":{"identifier":"a.b","platform":"UNIVERSAL"}}]}"#),
        ]
        transport = MockTransport(head + (tail ?? [
            (200, #"{"data":[{"type":"profiles","id":"P1","attributes":{"name":"xless a.b IOS_APP_STORE","profileState":"ACTIVE","profileType":"IOS_APP_STORE","profileContent":"\#(profile)","expirationDate":"\#(future)"}}]}"#),
            (200, #"{"data":[{"type":"certificates","id":"C1"}]}"#),
            (200, #"{"data":{"type":"bundleIds","id":"B1"}}"#),
        ]))
    }

    func run() async throws -> URL {
        try await SignStage.run(input: input, outputDir: outputDir, platform: .ios, config: config, project: project,
                                secrets: Secrets(env: ["XLESS_DIST_KEY": key.pem]),
                                client: ASCClient(credentials: testCreds, transport: transport, sleep: { _ in }))
    }

    var leftApps: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? []).filter { $0.hasSuffix(".app") }
    }
}

func teamProfile() -> [String: Any] { ["application-identifier": "ABCDE12345.a.b", "com.apple.developer.team-identifier": "ABCDE12345",
                                  "beta-reports-active": true, "get-task-allow": false] }

/// ASC replies for a forced profile refresh: list the old one, delete it, create `fresh`.
func refreshSteps(oldProfile: String, fresh: [String: Any]) throws -> [(Int, String)] {
    let freshB64 = try fakeProfile(fresh).base64EncodedString()
    return [
        (200, #"{"data":[{"type":"profiles","id":"P1","attributes":{"name":"xless a.b IOS_APP_STORE","profileState":"ACTIVE","profileType":"IOS_APP_STORE","profileContent":"\#(oldProfile)","expirationDate":"\#(future)"}}]}"#),
        (204, ""),
        (201, #"{"data":{"type":"profiles","id":"P2","attributes":{"profileContent":"\#(freshB64)"}}}"#),
    ]
}

@Test func entitlementGateFailureLeavesNoSignedBundle() async throws {
    let old = try fakeProfile(teamProfile()).base64EncodedString()
    let f = try SignFixture(profileEntitlements: teamProfile(), userEntitlements: ["aps-environment": "production"], tail: [
        (200, #"{"data":[{"type":"profiles","id":"P1","attributes":{"name":"xless a.b IOS_APP_STORE","profileState":"ACTIVE","profileType":"IOS_APP_STORE","profileContent":"\#(old)","expirationDate":"\#(future)"}}]}"#),
        (200, #"{"data":[{"type":"certificates","id":"C1"}]}"#),
        (200, #"{"data":{"type":"bundleIds","id":"B1"}}"#),
    ] + (try refreshSteps(oldProfile: old, fresh: teamProfile())))
    try FileManager.default.createDirectory(at: f.outputDir.appendingPathComponent("X.app"), withIntermediateDirectories: true)   // stale
    do { _ = try await f.run(); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .sign); #expect(e.cause.contains("aps-environment")) }
    #expect(f.leftApps.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: f.outputDir.path + ".partial"))
}

@Test func signFailureAfterCopyLeavesNoSignedBundle() async throws {
    // Everything checks out, then rcodesign fails (absent, or rejects the fake executable) after the bundle was copied.
    let f = try SignFixture(profileEntitlements: teamProfile())
    do { _ = try await f.run(); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .sign); #expect(e.cause.contains("rcodesign")) }
    #expect(f.leftApps.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: f.outputDir.path + ".partial"))
}

@Test func teamIDMismatchFailsAtSign() async throws {
    var profile = teamProfile()
    profile["com.apple.developer.team-identifier"] = "ZYXWV98765"
    profile["application-identifier"] = "ZYXWV98765.a.b"
    let f = try SignFixture(profileEntitlements: profile)
    do { _ = try await f.run(); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.description == "[sign] xless.yml teamID ABCDE12345 ≠ team ZYXWV98765 of the App Store Connect key — set teamID: ZYXWV98765 in xless.yml")
    }
    #expect(f.leftApps.isEmpty)
}

@Test func unmappedGatedKeyGrantedByProfileProceeds() async throws {
    var granted = teamProfile(); granted["com.apple.developer.associated-domains"] = ["applinks:example.com"]
    let f = try SignFixture(profileEntitlements: granted, userEntitlements: ["com.apple.developer.associated-domains": ["applinks:example.com"]])
    do { _ = try await f.run(); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.cause.contains("rcodesign")) }   // past every entitlement check; only the fake Mach-O fails
    #expect(f.transport.requests.allSatisfy { $0.httpMethod == "GET" })
}

@Test func unmappedGatedKeyNotGrantedRefreshesProfileThenRefuses() async throws {
    let old = try fakeProfile(teamProfile()).base64EncodedString()
    let f = try SignFixture(profileEntitlements: teamProfile(), userEntitlements: ["com.apple.developer.associated-domains": ["applinks:example.com"]], tail: [
        (200, #"{"data":[{"type":"profiles","id":"P1","attributes":{"name":"xless a.b IOS_APP_STORE","profileState":"ACTIVE","profileType":"IOS_APP_STORE","profileContent":"\#(old)","expirationDate":"\#(future)"}}]}"#),
        (200, #"{"data":[{"type":"certificates","id":"C1"}]}"#),
        (200, #"{"data":{"type":"bundleIds","id":"B1"}}"#),
    ] + (try refreshSteps(oldProfile: old, fresh: teamProfile())))
    do { _ = try await f.run(); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.cause == "entitlement 'com.apple.developer.associated-domains' is not granted by the provisioning profile for a.b; xless cannot enable this capability automatically")
        #expect(e.fix.contains("enable the matching capability for a.b at developer.apple.com/account/resources/identifiers"))
    }
    #expect(f.transport.requests.map { $0.httpMethod ?? "" }.suffix(3) == ["GET", "DELETE", "POST"])
    #expect(f.leftApps.isEmpty)
}

@Test func unmappedGatedKeyEnabledByHandIsPickedUpByRefresh() async throws {
    var granted = teamProfile(); granted["com.apple.developer.associated-domains"] = ["applinks:example.com"]
    let old = try fakeProfile(teamProfile()).base64EncodedString()
    let f = try SignFixture(profileEntitlements: teamProfile(), userEntitlements: ["com.apple.developer.associated-domains": ["applinks:example.com"]], tail: [
        (200, #"{"data":[{"type":"profiles","id":"P1","attributes":{"name":"xless a.b IOS_APP_STORE","profileState":"ACTIVE","profileType":"IOS_APP_STORE","profileContent":"\#(old)","expirationDate":"\#(future)"}}]}"#),
        (200, #"{"data":[{"type":"certificates","id":"C1"}]}"#),
        (200, #"{"data":{"type":"bundleIds","id":"B1"}}"#),
    ] + (try refreshSteps(oldProfile: old, fresh: granted)))
    do { _ = try await f.run(); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.cause.contains("rcodesign")) }
}

@Test func memoryLimitKeyIsPortalOnlyAndGoesToProfileCheck() async throws {
    let key = "com.apple.developer.kernel.increased-memory-limit"
    let old = try fakeProfile(teamProfile()).base64EncodedString()
    let f = try SignFixture(profileEntitlements: teamProfile(), userEntitlements: [key: true], tail: [
        (200, #"{"data":[{"type":"profiles","id":"P1","attributes":{"name":"xless a.b IOS_APP_STORE","profileState":"ACTIVE","profileType":"IOS_APP_STORE","profileContent":"\#(old)","expirationDate":"\#(future)"}}]}"#),
        (200, #"{"data":[{"type":"certificates","id":"C1"}]}"#),
        (200, #"{"data":{"type":"bundleIds","id":"B1"}}"#),
    ] + (try refreshSteps(oldProfile: old, fresh: teamProfile())))
    do { _ = try await f.run(); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.cause.contains("'\(key)' is not granted by the provisioning profile"))
        #expect(e.fix.contains("enable the matching capability"))
    }
    let reqs = f.transport.requests.map { "\($0.httpMethod ?? "") \($0.url!.path)" }
    #expect(!reqs.contains("POST /v1/bundleIdCapabilities"))
    #expect(reqs.suffix(3).map { $0.split(separator: " ")[0] } == ["GET", "DELETE", "POST"])
}
