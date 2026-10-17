import Testing
import Foundation
@testable import XlessXcode
@testable import XlessCore

// MARK: Simulated entitlements (LD_ENTITLEMENTS_SECTION / _DER)

/// The DER Xcode 27.0 linked into HelloRN's simulator executable (`__TEXT,__ents_der`, from
/// `HelloRN.app-Simulated.xcent.der`): `[APPLICATION 16] { INTEGER 1, [CONTEXT 16] { SEQUENCE { key, value } } }`.
@Test func entitlementsDERMatchesXcodesSimulatedEntitlements() {
    let ents = JSON.object(["application-identifier": .string("ABCDE12345.com.example.hellorn")])
    let measured = "703f020101b03a30380c166170706c69636174696f6e2d6964656e7469666965720c1e41424344453132333435"
        + "2e636f6d2e6578616d706c652e68656c6c6f726e"
    #expect(EntitlementsEncoding.der(ents).map { String(format: "%02x", $0) }.joined() == measured)
}

/// Every value type, as `codesign --generate-entitlement-der` (Xcode 27.0) encodes this dictionary: keys sorted
/// (nested ones too), booleans FF/00, minimal two's-complement integers, arrays as SEQUENCEs, long-form lengths.
@Test func entitlementsDEREncodesEveryValueTypeAsCodesign() {
    let ents = JSON.object([
        "b-true": .bool(true), "a-false": .bool(false), "c-int": .int(300), "d-neg": .int(-1),
        "e-array": .array([.string("x"), .string("y")]), "f-dict": .object(["z": .string("1"), "k": .bool(true)]),
        "g-empty-array": .array([]), "h-zero": .int(0), "i-128": .int(128),
    ])
    let measured = "708196020101b08190300c0c07612d66616c7365010100300b0c06622d747275650101ff300b0c05632d696e740202012c"
        + "300a0c05642d6e65670201ff30110c07652d617272617930060c01780c0179301a0c06662d64696374b01030060c016b0101ff"
        + "30060c017a0c013130110c0d672d656d7074792d61727261793000300b0c06682d7a65726f020100300b0c05692d3132380202"
        + "0080"
    #expect(EntitlementsEncoding.der(ents).map { String(format: "%02x", $0) }.joined() == measured)
    #expect(EntitlementsEncoding.integer(-129) == [0xFF, 0x7F] && EntitlementsEncoding.integer(65536) == [0x01, 0x00, 0x00])
}

/// Xcode's `<product>-Simulated.xcent` layout (tabs, sorted keys); an empty dictionary is `<dict/>`.
@Test func entitlementsXMLIsXcodesPlistLayout() throws {
    let xml = String(decoding: EntitlementsEncoding.xml(.object(["application-identifier": .string("T.a&b"), "g": .array([.bool(true)])])), as: UTF8.self)
    #expect(xml == """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>application-identifier</key>
        \t<string>T.a&amp;b</string>
        \t<key>g</key>
        \t<array>
        \t\t<true/>
        \t</array>
        </dict>
        </plist>

        """)
    let parsed = try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any]
    #expect(parsed?["application-identifier"] as? String == "T.a&b")
    #expect(String(decoding: EntitlementsEncoding.xml(.object([:])), as: UTF8.self).contains("<dict/>\n</plist>"))
}

// MARK: The simulator destination

@Test func buildRequestForTheSimulator() throws {
    let ws = try XcodeWorkspace.load(fixturesDir.appendingPathComponent("PodsStyle/PodsStyle.xcworkspace"))
    let data = try BuildRequest.make(workspace: ws, scheme: ws.scheme(named: "App"), configuration: "Release", overrides: [:],
                                     destination: .iphonesimulator)
    let r = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let dest = try #require((r["parameters"] as? [String: Any])?["activeRunDestination"] as? [String: Any])
    #expect(dest["platform"] as? String == "iphonesimulator" && dest["sdk"] as? String == "iphonesimulator")
    #expect(dest["targetArchitecture"] as? String == "arm64" && dest["supportedArchitectures"] as? [String] == ["arm64"])
    #expect(BuildRequest.Destination.iphonesimulator.platformName == "iphonesimulator")
}

/// Expo's ExpoModulesJSI build phase in a simulator build: its `build_slice iphonesimulator` call (`-sdk
/// iphonesimulator -destination "generic/platform=iOS Simulator"`), otherwise the device call's argv.
@Test func xcodebuildTakesExposSimulatorPackageBuild() throws {
    var argv = expoJSIBuild
    argv[argv.firstIndex(of: "-sdk")! + 1] = "iphonesimulator"
    argv[argv.firstIndex(of: "-destination")! + 1] = "generic/platform=iOS Simulator"
    guard case .buildPackage(let b) = try XcodebuildShim.parse(argv) else { Issue.record("not a package build"); return }
    #expect(b.destination == .iphonesimulator && b.scheme == "ExpoModulesJSI" && b.settings.count == 9)
    guard case .buildPackage(let device) = try XcodebuildShim.parse(expoJSIBuild) else { return }
    #expect(device.destination == .iphoneos)

    let pif = #"[{"type":"target","contents":{"guid":"PACKAGE-PRODUCT:ExpoModulesJSI","name":"ExpoModulesJSI-product"}}]"#
    var sim = b; sim.settings = []
    let r = try #require(try JSONSerialization.jsonObject(with: XcodebuildShim.packageRequest(packagePIF: Data(pif.utf8), build: sim, overrides: [:])) as? [String: Any])
    let params = try #require(r["parameters"] as? [String: Any])
    let table = ((params["overrides"] as? [String: Any])?["commandLine"] as? [String: Any])?["table"] as? [String: String]
    // -sdk iphonesimulator is SDKROOT; arm64 only (the generic simulator destination would also build x86_64).
    #expect(table == ["SDKROOT": "iphonesimulator", "ARCHS": "arm64"])
    #expect((params["activeRunDestination"] as? [String: Any])?["platform"] as? String == "iphonesimulator")
}

@Test(arguments: [
    ["build", "-scheme", "S", "-sdk", "iphonesimulator", "-destination", "generic/platform=iOS", "-derivedDataPath", "/d"],
    ["build", "-scheme", "S", "-sdk", "iphoneos", "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", "/d"],
    ["build", "-scheme", "S", "-sdk", "iphonesimulator", "-destination", "platform=iOS Simulator,name=iPhone 17", "-derivedDataPath", "/d"],
])
func xcodebuildRefusesMixedSimulatorDestinations(_ args: [String]) {
    #expect(throws: XcodebuildShim.Unsupported.self) { try XcodebuildShim.parse(args) }
}
