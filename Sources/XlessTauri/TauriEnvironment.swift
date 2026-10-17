import Foundation
import XlessCore

/// The environment of the two programs xless runs on Tauri's behalf: the frontend's `beforeBuildCommand` and cargo.
/// Values: docs/research/tauri-ios-contract.md, "Environment" (what tauri-cli and xcode-script set on the Mac) and
/// "Linux build — spike A findings" step 3 / spike B difference 4 (what the Linux host needs on top).
public enum TauriEnvironment {
    public static let target = "aarch64-apple-ios"

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
        let sdkRoot = try sdk.sdkPath("iphoneos").path
        let minOS = try resolved.config.platform(.ios).minimumOS
        let cflags = "--target=arm64-apple-ios\(minOS) -isysroot \(sdkRoot)"
        var env = [
            "SDKROOT": sdkRoot,
            "IPHONEOS_DEPLOYMENT_TARGET": minOS,
            "TAURI_IOS_APP_NAME": resolved.projectName,
            "TAURI_IOS_PROJECT_PATH": workRoot.appendingPathComponent(resolved.appleDir).path,
            "CC_aarch64_apple_ios": swift?.tool("clang") ?? "clang",
            "CXX_aarch64_apple_ios": swift?.tool("clang++") ?? "clang++",
            "AR_aarch64_apple_ios": "llvm-ar",
            "CFLAGS_aarch64_apple_ios": cflags,
            "CXXFLAGS_aarch64_apple_ios": cflags,
            "CARGO_TARGET_AARCH64_APPLE_IOS_LINKER": linkerWrapper(workRoot: workRoot).path,
        ]
        if let host {
            let underscored = host.replacingOccurrences(of: "-", with: "_")
            env["CARGO_TARGET_\(underscored.uppercased())_LINKER"] = "clang"
            env["CC_\(underscored)"] = "clang"
            env["CXX_\(underscored)"] = "clang++"
        }
        var patch: [String: String] = [:]
        if overlay.bundleID != resolved.tauri.identifier { patch["identifier"] = overlay.bundleID }
        if resolved.config.version != resolved.tauri.version { patch["version"] = resolved.config.version }
        if !patch.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: patch, options: [.sortedKeys])
            env["TAURI_CONFIG"] = String(decoding: data, as: UTF8.self)
        }
        return env
    }

    /// The file name must NOT end in `ld` (`ld`, `ld64`, `lld`, `-ld`): rustc infers the linker flavor from the linker's
    /// file name, and an `ld`-style name selects the ld64 flavor, which passes raw ld arguments (`-platform_version`,
    /// `-syslibroot`, `-dylib`, …) that this clang wrapper rejects. A `cc` name selects the cc flavor. RUSTFLAGS is
    /// deliberately not set to force the flavor: that would override the project's own `rustflags` configuration.
    static func linkerWrapper(workRoot: URL) -> URL { workRoot.appendingPathComponent(".xless/bin/xless-ios-cc") }

    /// cargo's linker for aarch64-apple-ios: `cargo rustc --crate-type staticlib` restricts only the app crate, and a
    /// dependency declaring `crate-type = ["cdylib", …]` is still linked as an iOS dylib (spike B difference 4).
    /// A wrapper, because cargo's `linker` takes no arguments.
    /// `swift`: the image's app Swift toolchain (Ruling R10), whose clang drives the link; nil: `clang` on PATH.
    public static func writeLinkerWrapper(minOS: String, sdk: DarwinSDK, workRoot: URL, swift: SwiftToolchain? = nil) throws -> URL {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let url = linkerWrapper(workRoot: workRoot)
        let text = """
            #!/bin/sh
            # Generated by xless: cargo's linker for aarch64-apple-ios (dependencies that declare a cdylib crate type).
            exec \(swift.map { q($0.tool("clang")) } ?? "clang") -target arm64-apple-ios\(minOS) -isysroot \(q(try sdk.sdkPath("iphoneos").path)) -fuse-ld=\(q(sdk.ld64.path)) -mlinker-version=907 "$@" \(q(try sdk.clangRuntime(platform: "ios").path))

            """
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
