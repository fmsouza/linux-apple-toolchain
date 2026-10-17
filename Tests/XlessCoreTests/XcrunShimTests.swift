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

@Test func toolCallsRunTheLinuxEquivalent() throws {
    let (sdk, _) = try fakeSDK()
    let which: (String) -> String? = { ["llvm-otool": "/usr/local/bin/llvm-otool", "llvm-lipo": "/usr/local/bin/llvm-lipo", "swiftc": "/usr/bin/swiftc"][$0] }
    // CocoaPods' embed-frameworks script and Expo's ExpoModulesJSI build script.
    #expect(try XcrunShim.resolve(["otool", "-LX", "/b/React"], sdk: sdk, which: which) == .exec(path: "/usr/local/bin/llvm-otool", args: ["-LX", "/b/React"]))
    #expect(try XcrunShim.resolve(["--sdk", "iphoneos", "lipo", "-info", "/b/x"], sdk: sdk, which: which) == .exec(path: "/usr/local/bin/llvm-lipo", args: ["-info", "/b/x"]))
    #expect(try XcrunShim.resolve(["swiftc", "--version"], sdk: sdk, which: which) == .exec(path: "/usr/bin/swiftc", args: ["--version"]))
    // A tool call is not a query: `run` (output only) refuses it, as do unknown tools.
    #expect(throws: XcrunShim.Unsupported.self) { try XcrunShim.run(["otool", "-L", "/b/x"], sdk: sdk, which: which) }
    #expect(throws: XcrunShim.Unsupported.self) { try XcrunShim.resolve(["xcodebuild", "-version"], sdk: sdk, which: which) }
    #expect(throws: XcrunShim.Unsupported.self) { try XcrunShim.resolve(["nm", "x"], sdk: sdk, which: which) }   // mapped, but not installed
}

@Test(arguments: [["clang", "-c", "x.c"], ["swiftc", "x.swift"], ["--sdk", "iphoneos", "clang", "-v"], ["--sdk", "iphoneos", "swiftc", "x.swift"],
                  ["swift", "--version"], ["clang++", "--version"], ["strip", "-S", "x"]])
func compilersAndUnverifiedToolsAreNotRun(args: [String]) throws {
    // Run without the SDK's target and sysroot, a compiler would silently produce Linux host output.
    let (sdk, _) = try fakeSDK()
    let which: (String) -> String? = { "/usr/bin/\($0)" }
    do { _ = try XcrunShim.resolve(args, sdk: sdk, which: which); Issue.record("expected a refusal for \(args)") }
    catch let e as XcrunShim.Unsupported { #expect(e.description == "xcrun shim: unsupported call: xcrun \(args.joined(separator: " "))") }
}

@Test func actoolIsFoundAndRunFromTheShimDirectory() throws {
    // CocoaPods' [CP] Copy Pods Resources: `[ "`xcrun --find actool`" ]`, then `xcrun actool … --compile <app> <catalogs>`.
    let (sdk, _) = try fakeSDK()
    let which: (String) -> String? = { "/usr/bin/\($0)" }
    let shim: (String) -> String? = { ["actool": "/opt/xless/shims/actool"][$0] }
    #expect(try XcrunShim.run(["--find", "actool"], sdk: sdk, which: which, shim: shim) == "/opt/xless/shims/actool\n")
    #expect(try XcrunShim.run(["--sdk", "iphoneos", "-f", "actool"], sdk: sdk, which: which, shim: shim) == "/opt/xless/shims/actool\n")
    let args = ["--output-format", "human-readable-text", "--notices", "--warnings", "--platform", "iphoneos", "--compile", "/b/A.app", "/p/Pod.xcassets"]
    #expect(try XcrunShim.resolve(["actool"] + args, sdk: sdk, which: which, shim: shim) == .exec(path: "/opt/xless/shims/actool", args: args))
    // Without the shim installed (the Tauri image), actool stays refused, and PATH is never searched for it.
    #expect(throws: XcrunShim.Unsupported.self) { try XcrunShim.run(["--find", "actool"], sdk: sdk, which: which) }
    #expect(throws: XcrunShim.Unsupported.self) { try XcrunShim.resolve(["actool", "--version"], sdk: sdk, which: which) }
    // Only actool: the other Xcode tools in the shim directory and the compilers are still refused through xcrun.
    let everything: (String) -> String? = { "/opt/xless/shims/\($0)" }
    for call in [["--find", "ibtool"], ["ibtool", "--version"], ["clang", "-c", "x.c"], ["swiftc", "x.swift"], ["copypng", "a", "b"]] {
        #expect(throws: XcrunShim.Unsupported.self, "\(call)") { try XcrunShim.resolve(call, sdk: sdk, which: which, shim: everything) }
    }
}

/// CocoaPods' `[CP] Embed Pods Frameworks` strips the architectures a simulator build does not target from a fat vendored
/// framework: `lipo -remove x86_64 -output <f> <f>`. `llvm-lipo` has no `-remove`; `-extract` of the rest writes the same
/// fat file Apple's lipo does (measured: one remaining slice keeps its fat header).
@Test func lipoRemoveBecomesExtractOfTheRemainingSlices() throws {
    let (sdk, _) = try fakeSDK()
    let which: (String) -> String? = { ["llvm-lipo": "/usr/local/bin/llvm-lipo"][$0] }
    let archs: (String) -> [String]? = { $0 == "/f/H" ? ["x86_64", "arm64"] : $0 == "/f/thin" ? ["arm64"] : nil }
    #expect(try XcrunShim.resolve(["lipo", "-remove", "x86_64", "-output", "/f/H", "/f/H"], sdk: sdk, which: which, lipoArchs: archs)
            == .exec(path: "/usr/local/bin/llvm-lipo", args: ["/f/H", "-extract", "arm64", "-output", "/f/H"]))
    for bad in [["lipo", "-remove", "arm64", "-remove", "x86_64", "-output", "/f/H", "/f/H"],   // nothing left
                ["lipo", "-remove", "i386", "-output", "/f/H", "/f/H"],                       // not in the file
                ["lipo", "-remove", "arm64", "-output", "/f/thin", "/f/thin"],                // not fat
                ["lipo", "-remove", "x86_64", "/f/H"],                                        // no -output
                ["lipo", "-remove", "x86_64", "-output", "/o", "/f/H", "-verify_arch", "arm64"],
                ["lipo", "-remove", "x86_64", "-output", "/o", "/f/unreadable"]] {
        #expect(throws: XcrunShim.Unsupported.self) { try XcrunShim.resolve(bad, sdk: sdk, which: which, lipoArchs: archs) }
    }
}
