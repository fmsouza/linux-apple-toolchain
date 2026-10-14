import Testing
import Foundation
@testable import XlessSDK
@testable import XlessCore

@Test(arguments: [("27.0", "2700"), ("16.4", "1640"), ("26.0.1", "2601"), ("15.0", "1500")])
func xcodeVersionCode(input: String, expected: String) throws {
    #expect(try ToolchainMetaCollector.xcodeVersionCode(input) == expected)
}

func makeFakeXcode() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FakeXcode-\(UUID()).app")
    let fm = FileManager.default
    func plist(_ dict: [String: Any], _ rel: String) throws {
        let url = root.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: url)
    }
    func json(_ dict: [String: Any], _ rel: String) throws {
        let url = root.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: dict).write(to: url)
    }
    try plist(["CFBundleShortVersionString": "27.0", "ProductBuildVersion": "27A266a"], "Contents/version.plist")
    for (plat, canon, build) in [("iPhoneOS", "iphoneos27.0", "23A340"), ("MacOSX", "macosx27.0", "26A120")] {
        let base = "Contents/Developer/Platforms/\(plat).platform"
        try plist(["DTPlatformBuild": build, "DTPlatformVersion": "27.0"], "\(base)/Info.plist")
        try json(["CanonicalName": canon, "Version": "27.0"], "\(base)/Developer/SDKs/\(plat).sdk/SDKSettings.json")
        try plist(["ProductBuildVersion": build], "\(base)/Developer/SDKs/\(plat).sdk/System/Library/CoreServices/SystemVersion.plist")
    }
    return root
}

@Test func collectsMetaFromXcodeTree() throws {
    let meta = try ToolchainMetaCollector.collect(xcodeApp: try makeFakeXcode(), buildMachineOSBuild: "26A100")
    #expect(meta.xcodeVersion == "2700")
    #expect(meta.xcodeBuild == "27A266a")
    #expect(meta.buildMachineOSBuild == "26A100")
    let ios = try meta.sdk(for: .ios)
    #expect(ios == PlatformSDKInfo(sdkName: "iphoneos27.0", sdkVersion: "27.0", sdkBuild: "23A340",
                                   platformName: "iphoneos", platformVersion: "27.0", platformBuild: "23A340"))
    #expect(try meta.sdk(for: .macos).sdkName == "macosx27.0")
}

@Test func missingXcodeIsSDKError() {
    do { _ = try ToolchainMetaCollector.collect(xcodeApp: URL(fileURLWithPath: "/nope.app"), buildMachineOSBuild: "x"); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .sdk) } catch { Issue.record("\(error)") }
}
