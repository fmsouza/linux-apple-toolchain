import Testing
import Foundation
@testable import XlessTauri
@testable import XlessCore

private var fm: FileManager { .default }

private func tree(_ files: [String]) throws -> URL {
    let root = fm.temporaryDirectory.appendingPathComponent("builder-\(UUID().uuidString)", isDirectory: true)
    for f in files {
        let url = root.appendingPathComponent(f)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }
    return root
}

@Suite struct TauriBuilderTests {
    @Test func picksThePackageManagerFromTheLockfile() throws {
        #expect(try TauriBuilder.installCommand(appRoot: tree(["package.json", "pnpm-lock.yaml"]))?.arguments
                == ["corepack", "pnpm", "install", "--frozen-lockfile"])
        #expect(try TauriBuilder.installCommand(appRoot: tree(["package.json", "package-lock.json"]))?.arguments == ["npm", "ci"])
        #expect(try TauriBuilder.installCommand(appRoot: tree(["package.json", "yarn.lock"]))?.arguments
                == ["corepack", "yarn", "install", "--frozen-lockfile"])
        #expect(try TauriBuilder.installCommand(appRoot: tree(["Cargo.toml"])) == nil)
    }

    @Test func refusesAmbiguousOrMissingLockfiles() throws {
        do {
            _ = try TauriBuilder.installCommand(appRoot: tree(["package.json", "pnpm-lock.yaml", "package-lock.json"]))
            Issue.record("two lockfiles accepted")
        } catch let e as XlessError {
            #expect(e.stage == .prepare && e.cause.contains("package-lock.json") && e.cause.contains("pnpm-lock.yaml"))
        }
        #expect(throws: XlessError.self) { try TauriBuilder.installCommand(appRoot: tree(["package.json"])) }
    }

    /// Every .m/.mm/.c/.cpp under the target's sources, skipping resources, folder references and `buildPhase: none`.
    @Test func findsNativeSources() throws {
        let apple = try tree(["Sources/app/main.mm", "Sources/app/bindings/bindings.h", "Sources/app/util.c", "Externals/arm64/release/libapp.a",
                              "app_iOS/Info.plist", "assets/x.c", "Skipped/y.m", "Extra/z.cpp", "Extra/w.m"])
        let sources: [XcodeGenTarget.Source] = [
            .init(path: "Sources", buildPhase: nil, type: nil), .init(path: "Externals", buildPhase: nil, type: nil),
            .init(path: "app_iOS", buildPhase: nil, type: nil), .init(path: "assets", buildPhase: "resources", type: "folder"),
            .init(path: "Skipped", buildPhase: "none", type: nil), .init(path: "Extra/z.cpp", buildPhase: nil, type: nil),
            .init(path: "Missing", buildPhase: nil, type: nil),
        ]
        let found = TauriBuilder.nativeSources(sources, appleDir: apple).map { String($0.path.dropFirst(apple.path.count + 1)) }
        #expect(found == ["Sources/app/main.mm", "Sources/app/util.c", "Extra/z.cpp"])
    }

    /// `LIBRARY_SEARCH_PATHS[arch=arm64]` of HelloTauri, expanded the way Xcode does for the release configuration.
    @Test func expandsHelloTauriLibrarySearchPaths() throws {
        let sdk = try fakeSDK(), (_, resolved) = try helloTauri()
        let work = URL(fileURLWithPath: "/W")
        let vars = try TauriBuilder.settingsVariables(resolved: resolved, workRoot: work, sdk: sdk)
        let paths = NativeLink.expandSettings(NativeLink.setting("LIBRARY_SEARCH_PATHS", in: resolved.target.settings) ?? "", vars: vars)
        let sdkRoot = try sdk.sdkPath("iphoneos").path, tc = sdk.toolchain.path
        #expect(paths == ["/W/src-tauri/gen/apple/Externals/arm64/release", "\(sdkRoot)/usr/lib/swift",
                          "\(tc)/usr/lib/swift/iphoneos", "\(tc)/usr/lib/swift-5.0/iphoneos"])
    }
}

@Suite struct RustupStepsTests {
    @Test func toolchainFileDecides() {
        #expect(TauriBuilder.rustupSteps(toolchainFile: true, activeToolchain: true) == [
            ["rustup", "toolchain", "install"], ["rustup", "target", "add", "aarch64-apple-ios"], ["rustup", "component", "add", "llvm-tools"]])
    }

    /// An app without rust-toolchain.toml (`tauri create`) gets stable, made the default only when there is none.
    @Test func withoutToolchainFileInstallsStable() {
        #expect(TauriBuilder.rustupSteps(toolchainFile: false, activeToolchain: false) == [
            ["rustup", "toolchain", "install", "stable", "--profile", "minimal"], ["rustup", "default", "stable"],
            ["rustup", "target", "add", "aarch64-apple-ios"], ["rustup", "component", "add", "llvm-tools"]])
        #expect(TauriBuilder.rustupSteps(toolchainFile: false, activeToolchain: true) == [
            ["rustup", "toolchain", "install", "stable", "--profile", "minimal"],
            ["rustup", "target", "add", "aarch64-apple-ios"], ["rustup", "component", "add", "llvm-tools"]])
    }
}
