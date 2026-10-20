import Testing
import Foundation
@testable import XlessTauri
@testable import XlessCore

/// A Darwin SDK bundle stand-in with the MacOSX 27.0 SDK and libclang_rt.osx.a.
private func macSDK() throws -> DarwinSDK {
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

@Suite struct RustAppleTests {
    @Test func rustupStepsPinnedToolchain() {
        #expect(RustApple.rustupSteps(toolchainFile: false, activeToolchain: false, toolchain: "1.97.0", targets: ["aarch64-apple-ios"]) == [
            ["rustup", "toolchain", "install", "1.97.0", "--profile", "minimal"],
            ["rustup", "target", "add", "--toolchain", "1.97.0", "aarch64-apple-ios"],
            ["rustup", "component", "add", "--toolchain", "1.97.0", "llvm-tools"],
        ])
    }

    @Test func rustupStepsUnpinnedUnchanged() {
        for (file, active) in [(true, true), (false, false), (false, true)] {
            for targets in [["aarch64-apple-ios"], TauriMacEnvironment.targets] {
                #expect(RustApple.rustupSteps(toolchainFile: file, activeToolchain: active, toolchain: nil, targets: targets)
                    == TauriBuilder.rustupSteps(toolchainFile: file, activeToolchain: active, targets: targets))
            }
        }
        #expect(RustApple.rustupSteps(toolchainFile: false, activeToolchain: false, targets: ["aarch64-apple-ios"]).contains(["rustup", "default", "stable"]))
    }

    @Test func iosCargoEnvHasNoTauriKeys() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ra-\(UUID().uuidString)")
        let env = try RustApple.iosCargoEnv(minOS: "17.0", sdk: fakeSDK(), workRoot: work, host: nil)
        #expect(env["SDKROOT"] != nil)
        #expect(env["IPHONEOS_DEPLOYMENT_TARGET"] == "17.0")
        #expect(env["CARGO_TARGET_AARCH64_APPLE_IOS_LINKER"] == work.appendingPathComponent(".xless/bin/xless-ios-cc").path)
        #expect(env.keys.allSatisfy { !$0.hasPrefix("TAURI_") })
        #expect(FileManager.default.isExecutableFile(atPath: work.appendingPathComponent(".xless/bin/xless-ios-cc").path))
    }

    @Test func macCargoEnvPerTarget() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ra-\(UUID().uuidString)")
        let env = try RustApple.macCargoEnv(target: "x86_64-apple-darwin", minOS: "11.0", sdk: macSDK(), workRoot: work, host: nil)
        #expect(env["MACOSX_DEPLOYMENT_TARGET"] == "11.0")
        #expect(env["CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER"]?.hasSuffix("xless-macos-cc-x86_64") == true)
        #expect(env["CARGO_PROFILE_RELEASE_STRIP"] == "false")
        #expect(env.keys.allSatisfy { !$0.hasPrefix("TAURI_") })
        #expect(FileManager.default.isExecutableFile(atPath: work.appendingPathComponent(".xless/bin/xless-macos-cc-x86_64").path))
    }

    @Test func unsupportedMacTargetIsRefused() throws {
        #expect(throws: XlessError.self) {
            try RustApple.macCargoEnv(target: "riscv64-apple-darwin", minOS: "11.0", sdk: macSDK(), workRoot: URL(fileURLWithPath: "/nonexistent"), host: nil)
        }
    }
}
