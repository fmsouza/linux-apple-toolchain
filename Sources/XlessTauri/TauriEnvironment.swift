import Foundation
import XlessCore

/// The environment of the two programs xless runs on Tauri's behalf: the frontend's `beforeBuildCommand` and cargo.
/// Values: docs/research/tauri-ios-contract.md, "Environment" (what tauri-cli and xcode-script set on the Mac) and
/// "Linux build — spike A findings" step 3 / spike B difference 4 (what the Linux host needs on top).
public enum TauriEnvironment {
    public static let target = RustApple.iosTarget

    /// `<arch>-unknown-linux-gnu` on Linux, where the image has no `cc` for rustc's and the `cc` crate's host builds;
    /// nil elsewhere.
    public static var defaultHost: String? {
        #if os(Linux)
        #if arch(arm64)
        return "aarch64-unknown-linux-gnu"
        #else
        return "x86_64-unknown-linux-gnu"
        #endif
        #else
        return nil
        #endif
    }

    /// The `beforeBuildCommand` hook env. TAURI_ENV_PLATFORM_VERSION is the host macOS version on a Mac; on Linux it is
    /// the iOS SDK version (open question 1). TAURI_ENV_DEBUG is not set for a release build.
    public static func frontend(sdk: DarwinSDK) throws -> [String: String] {
        [
            "TAURI_ENV_PLATFORM": "ios",
            "TAURI_ENV_ARCH": "aarch64",
            "TAURI_ENV_TARGET_TRIPLE": target,
            "TAURI_ENV_FAMILY": "unix",
            "TAURI_ENV_PLATFORM_VERSION": try sdk.sdkVersion("iphoneos"),
        ]
    }

    /// cargo's env. As on the Mac: SDKROOT, IPHONEOS_DEPLOYMENT_TARGET, TAURI_IOS_APP_NAME/PROJECT_PATH; no TAURI_ENV_*.
    /// Added for Linux: the iOS C toolchain told its target (the image's clang defaults to Linux), the iOS linker
    /// wrapper (`writeLinkerWrapper`) for dependencies that declare a cdylib, and clang for `host` build scripts.
    /// TAURI_CONFIG (a merge patch) only when the overlay changes the identifier or version tauri.conf.json would
    /// compile in; the Mac sets none.
    /// `swift`: the image's app Swift toolchain (Ruling R10), whose clang compiles the iOS C code; nil: `clang` on PATH.
    public static func cargo(resolved: ResolvedTauri, overlay: TauriOverlay, sdk: DarwinSDK, workRoot: URL,
                             host: String? = defaultHost, swift: SwiftToolchain? = nil) throws -> [String: String] {
        let minOS = try resolved.config.platform(.ios).minimumOS
        var env = try RustApple.iosEnvironment(minOS: minOS, sdk: sdk, workRoot: workRoot, host: host, swift: swift)
        env["TAURI_IOS_APP_NAME"] = resolved.projectName
        env["TAURI_IOS_PROJECT_PATH"] = workRoot.appendingPathComponent(resolved.appleDir).path
        var patch: [String: String] = [:]
        if overlay.bundleID != resolved.tauri.identifier { patch["identifier"] = overlay.bundleID }
        if resolved.config.version != resolved.tauri.version { patch["version"] = resolved.config.version }
        if !patch.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: patch, options: [.sortedKeys])
            env["TAURI_CONFIG"] = String(decoding: data, as: UTF8.self)
        }
        return env
    }

    static func linkerWrapper(workRoot: URL) -> URL { RustApple.iosLinkerWrapper(workRoot: workRoot) }

    /// cargo's linker for aarch64-apple-ios (see `RustApple.writeIOSLinkerWrapper`).
    @discardableResult
    public static func writeLinkerWrapper(minOS: String, sdk: DarwinSDK, workRoot: URL, swift: SwiftToolchain? = nil) throws -> URL {
        try RustApple.writeIOSLinkerWrapper(minOS: minOS, sdk: sdk, workRoot: workRoot, swift: swift)
    }
}
