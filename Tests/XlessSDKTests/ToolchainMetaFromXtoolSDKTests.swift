import Testing
import Foundation
@testable import XlessSDK
@testable import XlessCore

/// A synthetic xtool SDK tree (values made up for the test, not Apple's files).
private func makeFakeXtoolSDK() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FakeXtoolSDK-\(UUID()).xtoolsdk")
    let fm = FileManager.default
    func write(_ data: Data, _ rel: String) throws {
        let url = root.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    func plist(_ dict: [String: Any], _ rel: String) throws {
        try write(PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0), rel)
    }
    for (plat, canon, sdkBuild, platBuild) in [("iPhoneOS", "iphoneos27.0", "1A111", "1A112"), ("MacOSX", "macosx27.0", "1B221", "1B222")] {
        let base = "Developer/Platforms/\(plat).platform"
        try plist(["DTPlatformBuild": platBuild, "DTPlatformVersion": "27.0"], "\(base)/Info.plist")
        try write(JSONSerialization.data(withJSONObject: ["CanonicalName": canon, "Version": "27.0"]), "\(base)/Developer/SDKs/\(plat).sdk/SDKSettings.json")
        try plist(["ProductBuildVersion": sdkBuild], "\(base)/Developer/SDKs/\(plat).sdk/System/Library/CoreServices/SystemVersion.plist")
    }
    return root
}

private let xcode = KnownXcode(build: "TEST1", shortVersion: "27.0", appleSwift: "6.9", buildMachineOSBuild: "9Z999", xipSHA256: [])

@Test func collectsMetaFromXtoolSDK() throws {
    let meta = try ToolchainMetaCollector.collect(xtoolSDK: try makeFakeXtoolSDK(), xcode: xcode)
    let expected = ToolchainMeta(
        xcodeVersion: "2700", xcodeBuild: "TEST1", buildMachineOSBuild: "9Z999", compiler: ToolchainMeta.clangCompiler,
        platforms: [
            "iphoneos": PlatformSDKInfo(sdkName: "iphoneos27.0", sdkVersion: "27.0", sdkBuild: "1A111", platformName: "iphoneos",
                                        platformVersion: "27.0", platformBuild: "1A112"),
            "macosx": PlatformSDKInfo(sdkName: "macosx27.0", sdkVersion: "27.0", sdkBuild: "1B221", platformName: "macosx",
                                      platformVersion: "27.0", platformBuild: "1B222"),
        ],
        swiftVersion: "6.9")
    #expect(meta == expected)
}

@Test func missingPlatformThrows() throws {
    let empty = FileManager.default.temporaryDirectory.appendingPathComponent("EmptySDK-\(UUID())")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    #expect(throws: XlessError.self) { try ToolchainMetaCollector.collect(xtoolSDK: empty, xcode: xcode) }
}
