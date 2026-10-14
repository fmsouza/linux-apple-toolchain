import Testing
import Foundation
@testable import XlessSign
@testable import XlessASC
@testable import XlessCore

/// A project + finalized bundle + mock App Store Connect that returns a matching certificate, the bundle ID
/// and an active profile with `profileEntitlements`.
struct SignFixture {
    let project: URL, input: URL, outputDir: URL, key: SigningKey, transport: MockTransport, config: ProjectConfig

    init(profileEntitlements: [String: Any], userEntitlements: [String: Any] = [:], teamID: String = "ABCDE12345") throws {
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
        transport = MockTransport([
            (200, #"{"data":[\#(certJSON(id: "C1", der: try selfSigned(key)))]}"#),
            (200, #"{"data":[{"type":"bundleIds","id":"B1","attributes":{"identifier":"a.b","platform":"UNIVERSAL"}}]}"#),
            (200, #"{"data":[{"type":"profiles","id":"P1","attributes":{"name":"xless a.b IOS_APP_STORE","profileState":"ACTIVE","profileType":"IOS_APP_STORE","profileContent":"\#(profile)","expirationDate":"\#(future)"}}]}"#),
            (200, #"{"data":[{"type":"certificates","id":"C1"}]}"#),
            (200, #"{"data":{"type":"bundleIds","id":"B1"}}"#),
        ])
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

@Test func entitlementGateFailureLeavesNoSignedBundle() async throws {
    let f = try SignFixture(profileEntitlements: teamProfile(), userEntitlements: ["aps-environment": "production"])
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
