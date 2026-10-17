import Testing
import Foundation
@testable import XlessReactNative
@testable import XlessXcode
@testable import XlessCore
import XlessASC

private var fm: FileManager { .default }

private func tmp(_ tag: String) throws -> URL {
    let u = fm.temporaryDirectory.appendingPathComponent("rn-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func write(_ url: URL, _ text: String) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private var repo: URL {
    var dir = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { dir.deleteLastPathComponent() }
    return dir
}

private struct ComputeCalled: Error {}

/// An overlay file next to an `app/` source holding `files`; the work root is a fresh directory (no work copy).
private func rnOverlay(_ yaml: String, files: [String: String] = [:]) throws -> (url: URL, env: [String: String]) {
    let dir = try tmp("nb")
    for (name, text) in files { try write(dir.appendingPathComponent("app/\(name)"), text) }
    let url = dir.appendingPathComponent("o.yml")
    try write(url, "type: react-native\nsource: app\nteamID: ABCDE12345\n" + yaml)
    return (url, ["HOME": dir.path, "XLESS_WORK_ROOT": dir.appendingPathComponent("work").path])
}

/// compute that reports what it was asked for.
private let echo: NextBuild.Compute = { version, bundleID in "\(version) \(bundleID)" }

@Test func aFixedBuildIsPrintedAsIsWithoutAppStoreConnect() async throws {
    let (url, env) = try rnOverlay("scheme: App\nbundleIDs: { App: com.example.app }\nversion: 2.0.0\nbuild: 7\n")
    let out = try await NextBuild.forOverlay(at: url, sourceOverride: nil, env: env) { _, _ in throw ComputeCalled() }
    #expect(out == "7")
}

@Test func aDatedBuildWithoutCredentialsIsAConfigError() async throws {
    let (url, env) = try rnOverlay("scheme: App\nbundleIDs: { App: com.example.app }\nversion: 2.0.0\n")
    do {
        _ = try await NextBuild.forOverlay(at: url, sourceOverride: nil, env: env) { version, bundleID in
            try await withStage(.config) { try await DatedBuildNumber.compute(version: version, bundleID: bundleID, secrets: Secrets(env: [:])) }
        }
        Issue.record("no error")
    } catch let e as XlessError {
        #expect(e.stage == .config)
        #expect(e.cause.contains("needs App Store Connect credentials"))
    }
}

@Test func theVersionComesFromTheOverlayThenAppJsonThenPackageJson() async throws {
    let ids = "scheme: App\nbundleIDs: { App: com.example.app, Ext: com.example.app.ext }\n"
    let appJSON = #"{"expo": {"version": "1.1.0"}}"#, packageJSON = #"{"version": "1.2.3"}"#
    for (yaml, files, want) in [
        (ids + "version: 2.0.0\n", ["app.json": appJSON, "package.json": packageJSON], "2.0.0"),
        (ids, ["app.json": appJSON, "package.json": packageJSON], "1.1.0"),
        (ids, ["package.json": packageJSON], "1.2.3"),
    ] {
        let (url, env) = try rnOverlay(yaml, files: files)
        // the app target's entry: the one named like the scheme
        #expect(try await NextBuild.forOverlay(at: url, sourceOverride: nil, env: env, compute: echo) == "\(want) com.example.app")
    }
}

@Test func anOverlayWhoseAppTargetCannotBeToldIsAConfigError() async throws {
    let (url, env) = try rnOverlay("scheme: Main\nbundleIDs: { A: com.example.a, B: com.example.b }\nversion: 1.0.0\n")
    do {
        _ = try await NextBuild.forOverlay(at: url, sourceOverride: nil, env: env, compute: echo)
        Issue.record("no error")
    } catch let e as XlessError {
        #expect(e.stage == .config)
        #expect(e.cause.contains("cannot tell which bundleIDs entry is the app"))
    }
}

@Test func aTauriOverlayGoesToTheTauriResolution() async throws {
    let url = repo.appendingPathComponent("samples/HelloTauri/xless.overlay.example.yml")
    let source = repo.appendingPathComponent("samples/HelloTauri").path
    let viaDispatch = try await NextBuild.forOverlay(at: url, sourceOverride: source, compute: echo)
    #expect(viaDispatch == "1.0.0 com.example.hellotauri")   // tauri.conf.json's version, the overlay's bundleID
    #expect(try await NextBuild.tauri(at: url, sourceOverride: source, compute: echo) == viaDispatch)
}

// MARK: configuration switches

/// The PodsStyle fixture's Pods project, with its one script phase named `name` and running `script`.
private func pods(phaseName name: String, script: String) throws -> URL {
    var fixture = URL(fileURLWithPath: #filePath)
    for _ in 0..<2 { fixture.deleteLastPathComponent() }
    fixture.appendPathComponent("XlessXcodeTests/Fixtures/PodsStyle/Pods")
    let ios = try tmp("switch").appendingPathComponent("ios")
    try fm.createDirectory(at: ios, withIntermediateDirectories: true)
    try fm.copyItem(at: fixture, to: ios.appendingPathComponent("Pods"))
    let pbx = ios.appendingPathComponent("Pods/Pods.xcodeproj/project.pbxproj")
    var text = try String(contentsOf: pbx, encoding: .utf8)
    let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
    text = text.replacingOccurrences(of: #"name = "[CP-User] Prepare vendored";"#, with: "name = \"\(name)\";")
    text = text.replacingOccurrences(of: #"shellScript = "echo \"vendored ${CONFIGURATION}\" > \"${DERIVED_FILE_DIR}/vendored.stamp\"\n";"#,
                                     with: "shellScript = \"\(escaped)\";")
    // the phase's target (the aggregate Vendored) gets what a pod target's xcconfig sets
    for id in ["038C7A20A7734FBE1065CB67 /* Release */", "373918C62EAD36ECD72854E6 /* Debug */"] {
        text = text.replacingOccurrences(of: "\(id) = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n",
                                         with: "\(id) = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n"
                                             + "\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = \"$(inherited) COCOAPODS=1\";\n\t\t\t\tPODS_ROOT = \"${SRCROOT}\";\n")
    }
    try Data(text.utf8).write(to: pbx)
    return ios
}

/// A switch as Expo writes it: the configuration from GCC_PREPROCESSOR_DEFINITIONS, then work relative to PODS_ROOT.
private let expoLike = """
    CONFIG="release"
    if echo "$GCC_PREPROCESSOR_DEFINITIONS" | grep -q "DEBUG=1"; then
      CONFIG="debug"
    fi
    echo "$CONFIG|$PODS_ROOT|$(pwd -P)|$GCC_PREPROCESSOR_DEFINITIONS" > "$PODS_ROOT/switch.out"
    """

@Test func onlyTheConfigurationSwitchPhasesAreSelected() throws {
    for (name, selected) in [
        ("[CP-User] [Expo] Switch ExpoModulesCore XCFramework for build configuration", true),
        ("[CP-User] [RNCore] Replace React Native Core for the right configuration, if needed", true),
        ("[CP-User] [Hermes] Replace Hermes for the right configuration, if needed", true),
        ("[CP-User] [Expo] Resolve ExpoModulesCore dSYM source maps", false),
        ("[CP-User] Generate Specs", false),
        ("[CP] Copy XCFrameworks", false),
    ] {
        #expect(ConfigurationSwitches.isSwitch(name) == selected, "\(name)")
    }
    let ios = try pods(phaseName: "[CP-User] [Expo] Switch CoreLib XCFramework for build configuration", script: expoLike)
    let project = try XcodeProject.load(ios.appendingPathComponent("Pods/Pods.xcodeproj"))
    #expect(ConfigurationSwitches.phases(in: project).map(\.phase.target) == ["Vendored"])
    let untouched = try pods(phaseName: "[CP-User] Prepare vendored", script: expoLike)
    #expect(ConfigurationSwitches.phases(in: try XcodeProject.load(untouched.appendingPathComponent("Pods/Pods.xcodeproj"))).isEmpty)
    #expect(try ConfigurationSwitches.run(ios: untouched, configuration: "Release", env: [:], baseEnvironment: ProcessInfo.processInfo.environment,
                                          passthrough: false).isEmpty)
}

@Test func aSwitchRunsAsTheBuildWouldRunIt() throws {
    let ios = try pods(phaseName: "[CP-User] [Expo] Switch CoreLib XCFramework for build configuration", script: expoLike)
    let podsDir = ios.appendingPathComponent("Pods").resolvingSymlinksInPath().path
    let out = ios.appendingPathComponent("Pods/switch.out")
    let env = ProcessInfo.processInfo.environment
    // Release: the target's xcconfig over the project's Release settings ($(inherited) evaluated level by level)
    let ran = try ConfigurationSwitches.run(ios: ios, configuration: "Release", env: [:], baseEnvironment: env, passthrough: false)
    #expect(ran == ["Vendored: [CP-User] [Expo] Switch CoreLib XCFramework for build configuration"])
    var fields = try String(contentsOf: out, encoding: .utf8).trimmingCharacters(in: .newlines).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    #expect(fields[0] == "release")
    #expect(URL(fileURLWithPath: fields[1]).resolvingSymlinksInPath().path == podsDir)   // PODS_ROOT = ${SRCROOT}
    #expect(URL(fileURLWithPath: fields[2]).resolvingSymlinksInPath().path == podsDir)   // run in the project's directory
    #expect(fields[3] == "COCOAPODS=1")
    // Debug: the project's DEBUG=1 is inherited
    try ConfigurationSwitches.run(ios: ios, configuration: "Debug", env: [:], baseEnvironment: env, passthrough: false)
    fields = try String(contentsOf: out, encoding: .utf8).trimmingCharacters(in: .newlines).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    #expect(fields[0] == "debug")
    #expect(fields[3] == "DEBUG=1 COCOAPODS=1")
}

@Test func aFailingSwitchStopsPrepareNamingThePhase() throws {
    let ios = try pods(phaseName: "[CP-User] [RNDeps] Replace React Native Dependencies for the right configuration, if needed", script: "exit 3")
    do {
        try ConfigurationSwitches.run(ios: ios, configuration: "Release", env: [:], baseEnvironment: ProcessInfo.processInfo.environment, passthrough: false)
        Issue.record("no error")
    } catch let e as XlessError {
        #expect(e.stage == .prepare)
        #expect(e.cause.hasPrefix("Vendored's phase '[CP-User] [RNDeps] Replace React Native Dependencies for the right configuration, if needed' failed"))
    }
    // no Pods project yet: nothing to run
    #expect(try ConfigurationSwitches.run(ios: try tmp("none"), configuration: "Release", env: [:], baseEnvironment: [:], passthrough: false).isEmpty)
}

@Test func switchSettingErrorsAreReportedAsPrepareErrors() throws {
    // TargetSettings (shared with the build stage) throws `build` errors: a configuration the Pods project lacks, an
    // unreadable base xcconfig. During prepare they must exit 19, not 12.
    let ios = try pods(phaseName: "[CP-User] [Expo] Switch CoreLib XCFramework for build configuration", script: expoLike)
    let e = #expect(throws: XlessError.self) {
        try ConfigurationSwitches.run(ios: ios, configuration: "Staging", env: [:], baseEnvironment: ProcessInfo.processInfo.environment, passthrough: false)
    }
    #expect(e?.stage == .prepare)
    #expect(e?.cause.contains("Staging") == true)
}
