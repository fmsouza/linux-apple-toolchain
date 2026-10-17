import Testing
import Foundation
@testable import XlessTauri
@testable import XlessCore

/// A Darwin SDK bundle stand-in with the MacOSX 27.0 SDK and the toolchain's libclang_rt.osx.a (under a clang version dir).
private func fakeMacSDK() throws -> DarwinSDK {
    let fm = FileManager.default
    let bundle = fm.temporaryDirectory.appendingPathComponent("sdk-\(UUID().uuidString)/darwin.xtoolsdk", isDirectory: true)
    let sdk = bundle.appendingPathComponent("Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk")
    try fm.createDirectory(at: sdk, withIntermediateDirectories: true)
    try #"{"Version":"27.0"}"#.write(to: sdk.appendingPathComponent("SDKSettings.json"), atomically: true, encoding: .utf8)
    let rt = bundle.appendingPathComponent("Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/23/lib/darwin")
    try fm.createDirectory(at: rt, withIntermediateDirectories: true)
    try Data().write(to: rt.appendingPathComponent("libclang_rt.osx.a"))
    return DarwinSDK(bundle: bundle)
}

private func resolvedMac(bundleID: String = "com.example.hello", extra: String = "") throws -> ResolvedTauriMac {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("macenv-\(UUID().uuidString)")
    let dir = root.appendingPathComponent("src-tauri")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try #"{"productName":"Hello","version":"1.0.0","identifier":"com.example.hello"}"#.write(to: dir.appendingPathComponent("tauri.conf.json"), atomically: true, encoding: .utf8)
    try #"{"bundle":{"macOS":{"minimumSystemVersion":"13.0"}}}"#.write(to: dir.appendingPathComponent("tauri.macos.conf.json"), atomically: true, encoding: .utf8)
    let overlay = try TauriOverlay.parse(yaml: "type: tauri\nbundleID: \(bundleID)\nteamID: ABCDE12345\n\(extra)", name: "hello")
    return try TauriProject.resolveMac(overlay: overlay, source: root)
}

@Suite struct TauriMacEnvironmentTests {
    /// Contract, "macOS (desktop)" › Environment, with TAURI_ENV_PLATFORM_VERSION the SDK version on Linux.
    @Test func frontendEnvironmentMatchesTheContract() throws {
        #expect(try TauriMacEnvironment.frontend(sdk: fakeMacSDK()) == [
            "TAURI_ENV_PLATFORM": "darwin", "TAURI_ENV_ARCH": "universal", "TAURI_ENV_TARGET_TRIPLE": "universal-apple-darwin",
            "TAURI_ENV_FAMILY": "unix", "TAURI_ENV_PLATFORM_VERSION": "27.0",
        ])
    }

    /// Contract, "macOS — spike B", step 3.
    @Test func cargoEnvironmentMatchesTheContract() throws {
        let sdk = try fakeMacSDK(), resolved = try resolvedMac()
        let sdkRoot = try sdk.sdkPath("macosx").path
        let env = try TauriMacEnvironment.cargo(resolved: resolved, target: "x86_64-apple-darwin", sdk: sdk, workRoot: URL(fileURLWithPath: "/W"), host: "aarch64-unknown-linux-gnu")
        #expect(env == [
            "SDKROOT": sdkRoot,
            "MACOSX_DEPLOYMENT_TARGET": "13.0",
            "CC_x86_64_apple_darwin": "clang",
            "CXX_x86_64_apple_darwin": "clang++",
            "AR_x86_64_apple_darwin": "llvm-ar",
            "CFLAGS_x86_64_apple_darwin": "--target=x86_64-apple-macos13.0 -isysroot \(sdkRoot)",
            "CXXFLAGS_x86_64_apple_darwin": "--target=x86_64-apple-macos13.0 -isysroot \(sdkRoot)",
            "CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER": "/W/.xless/bin/xless-macos-cc-x86_64",
            "CARGO_PROFILE_RELEASE_STRIP": "false",
            "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER": "clang",
            "CC_aarch64_unknown_linux_gnu": "clang",
            "CXX_aarch64_unknown_linux_gnu": "clang++",
        ])
        let arm = try TauriMacEnvironment.cargo(resolved: resolved, target: "aarch64-apple-darwin", sdk: sdk, workRoot: URL(fileURLWithPath: "/W"), host: nil)
        #expect(arm["CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER"] == "/W/.xless/bin/xless-macos-cc-arm64")
        #expect(arm["CFLAGS_aarch64_apple_darwin"] == "--target=arm64-apple-macos13.0 -isysroot \(sdkRoot)")
        #expect(arm.keys.allSatisfy { !$0.lowercased().contains("linux") })
    }

    /// The Mac sets no TAURI_CONFIG; xless adds one only when the overlay changes the identifier or version compiled in.
    @Test func tauriConfigOnlyForOverrides() throws {
        let sdk = try fakeMacSDK(), work = URL(fileURLWithPath: "/W")
        let same = try TauriMacEnvironment.cargo(resolved: resolvedMac(), target: "aarch64-apple-darwin", sdk: sdk, workRoot: work, host: nil)
        #expect(same["TAURI_CONFIG"] == nil)
        let both = try TauriMacEnvironment.cargo(resolved: resolvedMac(bundleID: "com.example.hello.linux", extra: "version: 2.0.0\n"),
                                                 target: "aarch64-apple-darwin", sdk: sdk, workRoot: work, host: nil)
        #expect(both["TAURI_CONFIG"] == #"{"identifier":"com.example.hello.linux","version":"2.0.0"}"#)
        let idOnly = try TauriMacEnvironment.cargo(resolved: resolvedMac(bundleID: "com.example.hello.linux"),
                                                   target: "x86_64-apple-darwin", sdk: sdk, workRoot: work, host: nil)
        #expect(idOnly["TAURI_CONFIG"] == #"{"identifier":"com.example.hello.linux"}"#)
    }

    @Test func unknownTargetsAreRejected() throws {
        #expect(throws: XlessError.self) {
            try TauriMacEnvironment.cargo(resolved: resolvedMac(), target: "aarch64-apple-ios", sdk: fakeMacSDK(), workRoot: URL(fileURLWithPath: "/W"))
        }
    }

    @Test func wrapperNameDoesNotEndInLd() throws {
        for target in TauriMacEnvironment.targets {
            let url = try TauriMacEnvironment.writeLinkerWrapper(target: target, minOS: "13.0", sdk: fakeMacSDK(), workRoot: FileManager.default.temporaryDirectory.appendingPathComponent("w-\(UUID().uuidString)"))
            let name = url.lastPathComponent
            #expect(name.hasPrefix("xless-macos-cc-"))
            #expect(!name.hasSuffix("ld") && !name.hasSuffix("ld64") && !name.hasSuffix("lld"))
        }
    }

    @Test func wrapperScriptLinksLikeTheSpike() throws {
        let sdk = try fakeMacSDK()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("w-\(UUID().uuidString)")
        let url = try TauriMacEnvironment.writeLinkerWrapper(target: "aarch64-apple-darwin", minOS: "13.0", sdk: sdk, workRoot: work)
        let text = try String(contentsOf: url, encoding: .utf8)
        let rt = try sdk.clangRuntime(platform: "osx").path
        #expect(rt.contains("/clang/23/"))   // located by globbing, not a hardcoded clang version
        #expect(text.contains("exec clang --target=arm64-apple-macos13.0 -isysroot '\(try sdk.sdkPath("macosx").path)' -fuse-ld='\(sdk.ld64.path)' -mlinker-version=907 -Wl,-framework,Foundation -Wl,-x \"$@\" '\(rt)'"))
        #expect(FileManager.default.isExecutableFile(atPath: url.path))
    }
}
