import Testing
import Foundation
@testable import XlessCargo
@testable import XlessCore
import XlessReactNative
import XlessTauri

private var fm: FileManager { .default }

private func tempDir() throws -> URL {
    let dir = fm.temporaryDirectory.appendingPathComponent("dispatch-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ url: URL, _ text: String) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func git(_ dir: URL, _ args: String...) throws {
    _ = try Shell.run("git", ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "-C", dir.path] + args, stage: .prepare)
}

/// `dir/app`: a git repository whose workspace gives `hello-mobile` version 0.10.0. `dir/hello.yml`: a cargo overlay
/// with `source: app`, `build`, and `extra` appended. The work root is a fresh directory (no work copy).
private func cargoOverlay(build: String = "dated", ios: Bool = true, iosExtra: String = "", extra: String = "") throws -> (url: URL, dir: URL, env: [String: String]) {
    let dir = try tempDir(), app = dir.appendingPathComponent("app")
    try write(app.appendingPathComponent("Cargo.toml"), "[workspace]\nmembers = [\"crates/*\"]\n[workspace.package]\nversion = \"0.10.0\"\n")
    try write(app.appendingPathComponent("crates/hello-mobile/Cargo.toml"), "[package]\nname = \"hello-mobile\"\nversion.workspace = true\n")
    try git(app, "init", "-q")
    try git(app, "add", "-A")
    try git(app, "commit", "-q", "-m", "init")
    let iosBlock = ios ? """
    ios:
      package: hello-mobile
      product: Hello
      minimumOS: "17.0"
      assets: Assets.xcassets
    \(iosExtra)
    """ : """
    macos:
      package: hello-mobile
      product: Hello
      minimumOS: "11.0"
    """
    let url = dir.appendingPathComponent("hello.yml")
    try write(url, "type: cargo\nsource: app\nbundleID: com.example.hello\nteamID: ABCDE12345\nbuild: \(build)\n\(extra)\n\(iosBlock)\n")
    return (url, dir, ["HOME": dir.path, "XLESS_WORK_ROOT": dir.appendingPathComponent("work").path])
}

private struct ComputeCalled: Error {}

@Suite struct ContextDispatchTests {
    @Test func nextBuildForCargoOverlay() async throws {
        let (url, _, env) = try cargoOverlay()
        let out = try await NextBuild.forOverlay(at: url, sourceOverride: nil, env: env) { version, bundleID in
            #expect(bundleID == "com.example.hello")
            return "\(version).2026102001"
        }
        #expect(out == "0.10.0.2026102001")
    }

    @Test func nextBuildForCargoUsesTheIOSBundleIDAndTheShortVersion() async throws {
        let (url, _, env) = try cargoOverlay(iosExtra: "  bundleID: com.example.hello.ios", extra: "version: 1.2.0-beta.1")
        let out = try await NextBuild.forOverlay(at: url, sourceOverride: nil, env: env) { version, bundleID in "\(version) \(bundleID)" }
        #expect(out == "1.2.0 com.example.hello.ios")
    }

    @Test func nextBuildFixedForCargo() async throws {
        let (url, _, env) = try cargoOverlay(build: "7")
        let out = try await NextBuild.forOverlay(at: url, sourceOverride: nil, env: env) { _, _ in throw ComputeCalled() }
        #expect(out == "7")
    }

    @Test func nextBuildForAMacOnlyCargoOverlayIsAConfigError() async throws {
        let (url, _, env) = try cargoOverlay(ios: false)
        do {
            _ = try await NextBuild.forOverlay(at: url, sourceOverride: nil, env: env) { _, _ in throw ComputeCalled() }
            Issue.record("no error")
        } catch let e as XlessError {
            #expect(e.stage == .config)
            #expect(e.cause.contains("next-build is for iOS"), "cause: \(e.cause)")
        }
    }

    @Test func overlayKindFollowsTheTypeKey() throws {
        let dir = try tempDir()
        for (text, kind) in [("type: cargo\n", OverlayKind.cargo), ("type: react-native\n", .reactNative), ("type: tauri\n", .tauri), ("bundleID: x\n", .tauri)] {
            let url = dir.appendingPathComponent("\(UUID().uuidString).yml")
            try write(url, text)
            #expect(try OverlayKind.of(url) == kind)
        }
    }

    @Test func inspectRefusesCargo() throws {
        let (url, _, _) = try cargoOverlay()
        let kind = try OverlayKind.of(url)
        #expect(kind == .cargo)
        let e = #expect(throws: XlessError.self) { try kind.requireInspectable() }
        #expect(e?.stage == .config)
        #expect(e?.cause.contains("cargo") == true)
        try OverlayKind.tauri.requireInspectable()
        try OverlayKind.reactNative.requireInspectable()
    }

    @Test func cargoInputsCommandPrintsPathInputs() throws {
        let rev = String(repeating: "a", count: 40)
        let (url, dir, env) = try cargoOverlay(extra: """
        inputs:
          - { name: fonts, path: ../fonts, env: FONTS_DIR }
          - { name: models, git: "https://example.com/models.git", rev: \(rev), env: MODELS_DIR }
        """)
        let lines = try CargoInputs.hostMountLines(overlayAt: url, sourceOverride: nil, env: env)
        #expect(lines == ["fonts\t\(dir.appendingPathComponent("fonts").path)"])
        // --source moves where relative path inputs start.
        let other = dir.appendingPathComponent("elsewhere/app")
        #expect(try CargoInputs.hostMountLines(overlayAt: url, sourceOverride: other.path, env: env)
                == ["fonts\t\(dir.appendingPathComponent("elsewhere/fonts").path)"])
    }

    @Test func cargoInputsPrintsNothingWithoutPathInputs() throws {
        let (url, _, env) = try cargoOverlay()
        #expect(try CargoInputs.hostMountLines(overlayAt: url, sourceOverride: nil, env: env).isEmpty)
    }
}
