import Testing
import Foundation
@testable import XlessTauri
@testable import XlessCore

/// A Darwin SDK bundle stand-in: the iPhoneOS 27.0 SDK's SDKSettings.json and the toolchain's libclang_rt.ios.a.
func fakeSDK() throws -> DarwinSDK {
    let fm = FileManager.default
    let bundle = fm.temporaryDirectory.appendingPathComponent("sdk-\(UUID().uuidString)/darwin.xtoolsdk", isDirectory: true)
    let sdk = bundle.appendingPathComponent("Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk")
    try fm.createDirectory(at: sdk, withIntermediateDirectories: true)
    try #"{"Version":"27.0"}"#.write(to: sdk.appendingPathComponent("SDKSettings.json"), atomically: true, encoding: .utf8)
    let rt = bundle.appendingPathComponent("Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/21/lib/darwin")
    try fm.createDirectory(at: rt, withIntermediateDirectories: true)
    try Data().write(to: rt.appendingPathComponent("libclang_rt.ios.a"))
    return DarwinSDK(bundle: bundle)
}

/// HelloTauri's configuration: the sample's project.yml, tauri.conf.json (1.0.0, com.example.hellotauri) and
/// tauri.ios.conf.json (minimum iOS 16.0).
func helloTauri(bundleID: String = "com.example.hellotauri", _ overlayExtra: String = "") throws -> (overlay: TauriOverlay, resolved: ResolvedTauri) {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("hello-\(UUID().uuidString)", isDirectory: true)
    let apple = root.appendingPathComponent("src-tauri/gen/apple")
    try fm.createDirectory(at: apple, withIntermediateDirectories: true)
    try fixture("project.yml").write(to: apple.appendingPathComponent("project.yml"), atomically: true, encoding: .utf8)
    try #"{"productName":"HelloTauri","version":"1.0.0","identifier":"com.example.hellotauri","build":{"beforeBuildCommand":"node scripts/build.mjs","frontendDist":"../dist"}}"#
        .write(to: root.appendingPathComponent("src-tauri/tauri.conf.json"), atomically: true, encoding: .utf8)
    try #"{"bundle":{"iOS":{"minimumSystemVersion":"16.0"}}}"#
        .write(to: root.appendingPathComponent("src-tauri/tauri.ios.conf.json"), atomically: true, encoding: .utf8)
    let overlay = try TauriOverlay.parse(yaml: "type: tauri\nbundleID: \(bundleID)\nteamID: ABCDE12345\n\(overlayExtra)", name: "hello")
    return (overlay, try TauriProject.resolve(overlay: overlay, source: root))
}

@Suite struct TauriEnvironmentTests {
    /// The cargo environment recorded in docs/research/tauri-ios-contract.md ("Linux build — spike A findings", step 3,
    /// plus spike B difference 4: the iOS linker wrapper).
    @Test func cargoEnvironmentMatchesTheContract() throws {
        let sdk = try fakeSDK(), (overlay, resolved) = try helloTauri()
        let work = URL(fileURLWithPath: "/W")
        let sdkRoot = try sdk.sdkPath("iphoneos").path
        let env = try TauriEnvironment.cargo(resolved: resolved, overlay: overlay, sdk: sdk, workRoot: work, host: "aarch64-unknown-linux-gnu")
        #expect(env == [
            "SDKROOT": sdkRoot,
            "IPHONEOS_DEPLOYMENT_TARGET": "16.0",
            "TAURI_IOS_APP_NAME": "hello-tauri",
            "TAURI_IOS_PROJECT_PATH": "/W/src-tauri/gen/apple",
            "CC_aarch64_apple_ios": "clang",
            "CXX_aarch64_apple_ios": "clang++",
            "AR_aarch64_apple_ios": "llvm-ar",
            "CFLAGS_aarch64_apple_ios": "--target=arm64-apple-ios16.0 -isysroot \(sdkRoot)",
            "CXXFLAGS_aarch64_apple_ios": "--target=arm64-apple-ios16.0 -isysroot \(sdkRoot)",
            "CARGO_TARGET_AARCH64_APPLE_IOS_LINKER": "/W/.xless/bin/xless-ios-cc",
            "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER": "clang",
            "CC_aarch64_unknown_linux_gnu": "clang",
            "CXX_aarch64_unknown_linux_gnu": "clang++",
        ])
    }

    @Test func hostSettingsFollowTheHostTriple() throws {
        let sdk = try fakeSDK(), (overlay, resolved) = try helloTauri()
        let env = try TauriEnvironment.cargo(resolved: resolved, overlay: overlay, sdk: sdk, workRoot: URL(fileURLWithPath: "/W"), host: "x86_64-unknown-linux-gnu")
        #expect(env["CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER"] == "clang" && env["CC_x86_64_unknown_linux_gnu"] == "clang")
        #expect(env["CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER"] == nil)
        let mac = try TauriEnvironment.cargo(resolved: resolved, overlay: overlay, sdk: sdk, workRoot: URL(fileURLWithPath: "/W"), host: nil)
        #expect(mac.keys.filter { $0.contains("linux") || $0.contains("LINUX") }.isEmpty)
    }

    /// The Mac sets no TAURI_CONFIG (contract, "cargo"); xless adds one only when the overlay changes the identifier or
    /// version that tauri.conf.json would compile in (spec §4.2).
    @Test func tauriConfigOnlyForOverrides() throws {
        let sdk = try fakeSDK(), (overlay, resolved) = try helloTauri(bundleID: "com.example.hellotauri.linux", "version: 2.0.0\n")
        let env = try TauriEnvironment.cargo(resolved: resolved, overlay: overlay, sdk: sdk, workRoot: URL(fileURLWithPath: "/W"), host: nil)
        let json = try #require(env["TAURI_CONFIG"])
        let patch = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]
        #expect(patch == ["identifier": "com.example.hellotauri.linux", "version": "2.0.0"])
    }

    /// The `beforeBuildCommand` hook env (contract, "Environment"); TAURI_ENV_PLATFORM_VERSION is the iOS SDK version on
    /// Linux (open question 1); TAURI_ENV_DEBUG is not set for a release build.
    @Test func frontendEnvironmentMatchesTheContract() throws {
        #expect(try TauriEnvironment.frontend(sdk: fakeSDK()) == [
            "TAURI_ENV_PLATFORM": "ios",
            "TAURI_ENV_ARCH": "aarch64",
            "TAURI_ENV_TARGET_TRIPLE": "aarch64-apple-ios",
            "TAURI_ENV_FAMILY": "unix",
            "TAURI_ENV_PLATFORM_VERSION": "27.0",
        ])
    }

    @Test func linkerWrapperNameGetsTheCcFlavor() {
        let name = TauriEnvironment.linkerWrapper(workRoot: URL(fileURLWithPath: "/W")).lastPathComponent
        for suffix in ["ld", "ld64", "lld"] { #expect(!name.hasSuffix(suffix)) }
        #expect(name.hasSuffix("cc"))
    }

    @Test func linkerWrapperUsesTheAppleLinker() throws {
        let sdk = try fakeSDK()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("w-\(UUID().uuidString)", isDirectory: true)
        let wrapper = try TauriEnvironment.writeLinkerWrapper(minOS: "16.0", sdk: sdk, workRoot: work)
        #expect(wrapper.path == work.appendingPathComponent(".xless/bin/xless-ios-cc").path)
        #expect(FileManager.default.isExecutableFile(atPath: wrapper.path))
        let text = try String(contentsOf: wrapper, encoding: .utf8)
        let rt = try sdk.clangRuntime(platform: "ios").path
        #expect(text == """
            #!/bin/sh
            # Generated by xless: cargo's linker for aarch64-apple-ios (dependencies that declare a cdylib crate type).
            exec clang -target arm64-apple-ios16.0 -isysroot '\(try sdk.sdkPath("iphoneos").path)' -fuse-ld='\(sdk.ld64.path)' -mlinker-version=907 "$@" '\(rt)'

            """)
    }

    /// Ruling R10: with the image's app Swift toolchain, its clang compiles the iOS C code and drives the cdylib link.
    @Test func theAppSwiftToolchainsClangCompilesAndLinks() throws {
        let sdk = try fakeSDK(), (overlay, resolved) = try helloTauri()
        let swift = SwiftToolchain(version: "6.2.3", root: "/opt/xless/toolchains/swift-6.2.3")
        let env = try TauriEnvironment.cargo(resolved: resolved, overlay: overlay, sdk: sdk, workRoot: URL(fileURLWithPath: "/W"),
                                             host: "aarch64-unknown-linux-gnu", swift: swift)
        #expect(env["CC_aarch64_apple_ios"] == "/opt/xless/toolchains/swift-6.2.3/usr/bin/clang")
        #expect(env["CXX_aarch64_apple_ios"] == "/opt/xless/toolchains/swift-6.2.3/usr/bin/clang++")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("w-\(UUID().uuidString)", isDirectory: true)
        let text = try String(contentsOf: try TauriEnvironment.writeLinkerWrapper(minOS: "16.0", sdk: sdk, workRoot: work, swift: swift), encoding: .utf8)
        #expect(text.contains("exec '/opt/xless/toolchains/swift-6.2.3/usr/bin/clang' -target arm64-apple-ios16.0 "))
    }
}
