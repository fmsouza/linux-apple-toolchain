import Testing
import Foundation
@testable import XlessReactNative
@testable import XlessXcode
@testable import XlessCore

private var fm: FileManager { .default }

private func tree(_ files: [String: String]) throws -> URL {
    let root = fm.temporaryDirectory.appendingPathComponent("rn-contract-\(UUID().uuidString)", isDirectory: true)
    for (path, text) in files {
        let u = root.appendingPathComponent(path)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
    }
    return root
}

private func gemfileLock(pods: String = "1.15.2", bundler: String = "2.7.2") -> String {
    """
    GEM
      remote: https://rubygems.org/
      specs:
        cocoapods (\(pods))
          cocoapods-core (= \(pods))
        cocoapods-core (\(pods))

    PLATFORMS
      ruby

    DEPENDENCIES
      cocoapods (~> 1.15.2)

    BUNDLED WITH
       \(bundler)

    """
}

@Test func rubyVersionsComeFromTheNearestGemfileLock() throws {
    let src = try tree(["apps/client/Gemfile.lock": gemfileLock(), "Gemfile.lock": gemfileLock(pods: "1.16.0")])
    let app = src.appendingPathComponent("apps/client")
    #expect(ReactNativeContract.gemfileLock(appDir: app, root: src)?.path == app.appendingPathComponent("Gemfile.lock").path)
    try ReactNativeContract.checkRuby(appDir: app, root: src)
    #expect(ReactNativeContract.rubyVersions(gemfileLock: gemfileLock()) == ("1.15.2", "2.7.2"))
    // The root's lock is not in contract.
    #expect(throws: XlessError.self) { try ReactNativeContract.checkRuby(appDir: src.appendingPathComponent("other"), root: src) }
    #expect(throws: XlessError.self) { try ReactNativeContract.checkRuby(appDir: try tree(["Gemfile.lock": gemfileLock(bundler: "2.5.0")]), root: src) }
    let none = try tree(["package.json": "{}"])
    #expect(throws: XlessError.self) { try ReactNativeContract.checkRuby(appDir: none, root: none) }
}

@Test func javascriptVersionsAreWhatNodeResolvesFromTheApp() throws {
    let w = try tree([
        "node_modules/react-native/package.json": #"{"version": "0.86.2"}"#,
        "node_modules/expo/package.json": #"{"version": "57.0.11"}"#,
        "apps/client/package.json": "{}",
    ])
    let app = w.appendingPathComponent("apps/client")
    try ReactNativeContract.checkJavaScript(appDir: app, root: w)
    // The app's own node_modules wins over the root's (Node's resolution).
    try Data(#"{"version": "0.87.0"}"#.utf8).write(to: { let u = app.appendingPathComponent("node_modules/react-native/package.json")
        try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true); return u }())
    #expect(throws: XlessError.self) { try ReactNativeContract.checkJavaScript(appDir: app, root: w) }
    let noExpo = try tree(["node_modules/react-native/package.json": #"{"version": "0.86.0"}"#])
    #expect(throws: XlessError.self) { try ReactNativeContract.checkJavaScript(appDir: noExpo, root: noExpo) }
    let oldExpo = try tree(["node_modules/react-native/package.json": #"{"version": "0.86.0"}"#, "node_modules/expo/package.json": #"{"version": "56.0.1"}"#])
    #expect(throws: XlessError.self) { try ReactNativeContract.checkJavaScript(appDir: oldExpo, root: oldExpo) }
}

@Test func detectedVersionsSayWhetherTheyAreInContract() throws {
    let src = try tree(["Gemfile.lock": gemfileLock()])
    let work = try tree(["node_modules/react-native/package.json": #"{"version": "0.86.2"}"#, "node_modules/expo/package.json": #"{"version": "57.0.11"}"#])
    let d = ReactNativeContract.detect(appDir: ".", source: src, work: work)
    #expect(d == .init(reactNative: "0.86.2", expo: "57.0.11", cocoaPods: "1.15.2", bundler: "2.7.2") && d.inContract)
    #expect(!ReactNativeContract.detect(appDir: ".", source: src, work: src).inContract)   // nothing installed yet
}

@Test func inspectReportsWhatTheBuildWouldDo() throws {
    var dir = URL(fileURLWithPath: #filePath)
    for _ in 0..<2 { dir.deleteLastPathComponent() }
    let o = try ReactNativeOverlay.parse(yaml: """
        type: react-native
        scheme: HelloRN
        bundleIDs: { HelloRN: io.example.rn, HelloExtension: io.example.rn.HelloExtension }
        teamID: ABCDE12345
        version: 1.0.0
        env: { FEATURE_X: enabled }
        prepare: { run: [make config] }
        """, name: "hello")
    let empty = try tree(["x": ""])
    let early = try ReactNativeProject.resolve(overlay: o, source: empty, work: empty)
    let before = ReactNativeInspectReport.make(resolved: early, overlay: o, contract: .init(), native: nil, nextBuild: nil)
    #expect(before.contains("[workspace]\nworkspace: (run xless prepare to generate the Xcode project)"))
    #expect(before.contains("HelloRN: io.example.rn (app)") && before.contains("env: FEATURE_X\n") && before.contains("  | make config"))
    #expect(before.contains("status: incomplete") && !before.contains(empty.path))

    let fixture = dir.appendingPathComponent("XlessXcodeTests/Fixtures/HelloRN")
    let native = ReactNativeInspectReport.Native(workspace: try XcodeWorkspace.load(fixture.appendingPathComponent("HelloRN.xcodeproj")),
                                                 relativePath: "ios/HelloRN.xcworkspace")
    let after = ReactNativeInspectReport.make(resolved: early, overlay: o, contract: .init(reactNative: "0.86.2", expo: "57.0.11", cocoaPods: "1.15.2", bundler: "2.7.2"),
                                              native: native, nextBuild: nil)
    #expect(after.contains("embeds: HelloExtension (app-extension)"))
    #expect(after.contains("HelloRN: io.example.rn (project: com.example.hellorn)"))
    #expect(after.contains("HelloExtension: io.example.rn.HelloExtension (project: com.example.hellorn.HelloExtension)"))
    #expect(after.contains("[packages]\n(none)") && after.contains("status: in contract") && after.hasSuffix("\n") && !after.hasSuffix("\n\n"))
}
