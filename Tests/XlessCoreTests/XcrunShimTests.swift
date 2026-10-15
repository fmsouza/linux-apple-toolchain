import Foundation
import Testing
@testable import XlessCore

private func fakeSDK() throws -> (DarwinSDK, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("xcrun-\(UUID().uuidString)")
    let fm = FileManager.default
    for p in ["Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk",
              "Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk",
              "Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/21/lib/darwin",
              "toolset/bin"] {
        try fm.createDirectory(at: root.appendingPathComponent(p), withIntermediateDirectories: true)
    }
    try Data().write(to: root.appendingPathComponent("Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/21/lib/darwin/libclang_rt.ios.a"))
    try Data().write(to: root.appendingPathComponent("toolset/bin/ld64.lld"))
    try #"{"Version":"27.0"}"#.write(to: root.appendingPathComponent("Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk/SDKSettings.json"), atomically: true, encoding: .utf8)
    return (DarwinSDK(bundle: root), root)
}

@Test func showSDKPathResolvesVersionedSDK() throws {
    let (sdk, root) = try fakeSDK()
    let out = try XcrunShim.run(["--sdk", "iphoneos", "--show-sdk-path"], sdk: sdk, which: { _ in nil })
    #expect(out == root.appendingPathComponent("Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk").path + "\n")
}

@Test func showSDKVersionReadsSDKSettings() throws {
    let (sdk, _) = try fakeSDK()
    #expect(try XcrunShim.run(["--sdk", "iphoneos", "--show-sdk-version"], sdk: sdk, which: { _ in nil }) == "27.0\n")
}

@Test func findMapsToolsToLinuxEquivalents() throws {
    let (sdk, root) = try fakeSDK()
    let which: (String) -> String? = { ["clang": "/usr/bin/clang", "llvm-nm": "/usr/bin/llvm-nm", "llvm-ar": "/usr/bin/llvm-ar"][$0] }
    #expect(try XcrunShim.run(["--find", "clang"], sdk: sdk, which: which) == "/usr/bin/clang\n")
    #expect(try XcrunShim.run(["--find", "nm"], sdk: sdk, which: which) == "/usr/bin/llvm-nm\n")
    #expect(try XcrunShim.run(["--sdk", "iphoneos", "--find", "ld"], sdk: sdk, which: which) == root.appendingPathComponent("toolset/bin/ld64.lld").path + "\n")
}

@Test func unknownCallsAreRefusedWithTheirArgv() throws {
    let (sdk, _) = try fakeSDK()
    #expect(throws: XcrunShim.Unsupported.self) { try XcrunShim.run(["xcodebuild", "-version"], sdk: sdk, which: { _ in nil }) }
    do { _ = try XcrunShim.run(["--sdk", "watchos", "--show-sdk-path"], sdk: sdk, which: { _ in nil }) }
    catch let e as XcrunShim.Unsupported { #expect(e.description == "xcrun shim: unsupported call: xcrun --sdk watchos --show-sdk-path") }
}
