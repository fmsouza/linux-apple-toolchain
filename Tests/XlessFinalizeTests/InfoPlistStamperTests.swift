import Testing
import Foundation
@testable import XlessFinalize
@testable import XlessCore

let meta = ToolchainMeta(
    xcodeVersion: "2700", xcodeBuild: "27A266a", buildMachineOSBuild: "26A100", compiler: ToolchainMeta.clangCompiler,
    platforms: [
        "iphoneos": .init(sdkName: "iphoneos27.0", sdkVersion: "27.0", sdkBuild: "23A340", platformName: "iphoneos", platformVersion: "27.0", platformBuild: "23A340"),
        "macosx": .init(sdkName: "macosx27.0", sdkVersion: "27.0", sdkBuild: "26A120", platformName: "macosx", platformVersion: "27.0", platformBuild: "26A120"),
    ])

func config(_ extra: String = "") throws -> ProjectConfig {
    try ProjectConfig.parse(yaml: """
    bundleID: app.example.x
    teamID: ABCDE12345
    version: 2.1.0
    build: 9
    platforms:
      ios: { minimumOS: "17.0", product: X }
      macos: { minimumOS: "14.0", product: X }
    \(extra)
    """)
}

@Test func stampsIOS() throws {
    var p: [String: Any] = ["CFBundleIdentifier": "app.example.x", "CFBundleIconFile": "icon.png"]
    try InfoPlistStamper.stamp(&p, meta: meta, sdk: meta.sdk(for: .ios), platform: .ios, config: config())
    #expect(p["DTPlatformName"] as? String == "iphoneos")
    #expect(p["DTSDKName"] as? String == "iphoneos27.0")
    #expect(p["DTSDKBuild"] as? String == "23A340")
    #expect(p["DTPlatformBuild"] as? String == "23A340")
    #expect(p["DTPlatformVersion"] as? String == "27.0")
    #expect(p["DTXcode"] as? String == "2700")
    #expect(p["DTXcodeBuild"] as? String == "27A266a")
    #expect(p["DTCompiler"] as? String == ToolchainMeta.clangCompiler)
    #expect(p["BuildMachineOSBuild"] as? String == "26A100")
    #expect(p["CFBundleShortVersionString"] as? String == "2.1.0")
    #expect(p["CFBundleVersion"] as? String == "9")
    #expect(p["MinimumOSVersion"] as? String == "17.0")
    #expect(p["CFBundleSupportedPlatforms"] as? [String] == ["iPhoneOS"])
    #expect(p["LSMinimumSystemVersion"] == nil)
}

@Test func stampsMacOS() throws {
    var p: [String: Any] = [:]
    try InfoPlistStamper.stamp(&p, meta: meta, sdk: meta.sdk(for: .macos), platform: .macos, config: config())
    #expect(p["DTPlatformName"] as? String == "macosx")
    #expect(p["LSMinimumSystemVersion"] as? String == "14.0")
    #expect(p["MinimumOSVersion"] == nil)
    #expect(p["CFBundleSupportedPlatforms"] as? [String] == ["MacOSX"])
}
