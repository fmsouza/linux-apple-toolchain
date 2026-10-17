import Testing
import Foundation
@testable import XlessReactNative
@testable import XlessXcode
@testable import XlessCore

/// Xcode's `<product>-Simulated.xcent`: the target's entitlements plus `application-identifier`; the signing prefixes
/// become the team, and the overlay's edits apply as at sign.
@Test func simulatedEntitlementsAreTheTargetsPlusTheApplicationIdentifier() {
    let e = BuiltApp.Entitlements(target: "App", bundleID: "com.example.app", file: "App/App.entitlements", entitlements: .object([
        "keychain-access-groups": .array([.string("$(AppIdentifierPrefix)com.other.app")]),
        "com.apple.security.application-groups": .array([.string("group.com.other.app")]),
        "com.apple.developer.declared-age-range": .bool(true),
        "aps-environment": .string("development"),
    ]))
    let rewrites = EntitlementRewrites(replace: ["com.other.app": "com.example.app"], remove: ["com.apple.developer.declared-age-range"])
    #expect(SimulatorBuild.simulatedEntitlements(e, teamID: "ABCDE12345", rewrites: rewrites) == .object([
        "application-identifier": .string("ABCDE12345.com.example.app"),
        "keychain-access-groups": .array([.string("ABCDE12345.com.example.app")]),
        "com.apple.security.application-groups": .array([.string("group.com.example.app")]),
        "aps-environment": .string("development"),
    ]))
    // HelloRN's targets have empty entitlements files: Xcode's simulated entitlements hold only the identifier.
    let empty = BuiltApp.Entitlements(target: "HelloExtension", bundleID: "com.example.hellorn.HelloExtension", file: nil, entitlements: .object([:]))
    #expect(SimulatorBuild.simulatedEntitlements(empty, teamID: "ABCDE12345", rewrites: .none)
            == .object(["application-identifier": .string("ABCDE12345.com.example.hellorn.HelloExtension")]))
}

@Test func entitlementSectionsAreWrittenAndLinkedThroughSwiftBuildsSimulatorSettings() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-sim-ents-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let ents = JSON.object(["application-identifier": .string("ABCDE12345.com.example.hellorn")])
    let settings = try SimulatorBuild.entitlementSections(ents, target: "HelloRN", in: dir)
    #expect(settings == ["LD_ENTITLEMENTS_SECTION": dir.appendingPathComponent("HelloRN-Simulated.xcent").path,
                         "LD_ENTITLEMENTS_SECTION_DER": dir.appendingPathComponent("HelloRN-Simulated.xcent.der").path])
    #expect(try Data(contentsOf: URL(fileURLWithPath: settings["LD_ENTITLEMENTS_SECTION"]!)) == EntitlementsEncoding.xml(ents))
    #expect(try Data(contentsOf: URL(fileURLWithPath: settings["LD_ENTITLEMENTS_SECTION_DER"]!)) == EntitlementsEncoding.der(ents))
    #expect(SimulatorBuild.buildSettings == ["SDKROOT": "iphonesimulator", "ARCHS": "arm64"])
}

/// rcodesign signs ad hoc without a key; the app and each extension get the empty entitlements (as Xcode's
/// `codesign --sign - --entitlements <empty xcent>`), path-scoped for the extensions.
@Test func adHocSigningArguments() {
    let args = SimulatorBuild.adHocSignArguments(app: URL(fileURLWithPath: "/w/A.app"), nested: ["PlugIns/E.appex"],
                                                 emptyEntitlements: URL(fileURLWithPath: "/t/empty.xcent"))
    #expect(args == ["sign", "--entitlements-xml-file", "/t/empty.xcent", "--entitlements-xml-file", "PlugIns/E.appex:/t/empty.xcent", "/w/A.app"])
    #expect(!args.contains("--pem-file"))
}

@Test func simulatorBuildsHaveTheirOwnDerivedDataAndStageDirectory() throws {
    let work = URL(fileURLWithPath: "/cache/work/app")
    #expect(StagePaths.iosSimulator(project: work).app.path == "/cache/work/app/.xless/build/ios-simulator/app")
    #expect(StagePaths(project: work, platform: .ios).app.path == "/cache/work/app/.xless/build/ios/app")
}
