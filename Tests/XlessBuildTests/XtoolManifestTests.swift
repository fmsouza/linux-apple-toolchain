import Testing
import Foundation
@testable import XlessBuild
@testable import XlessCore

let cfgYAML = """
bundleID: app.example.helloship
teamID: ABCDE12345
version: 1.0.0
build: 1
platforms:
  ios: { minimumOS: "17.0", product: HelloShip }
privacyManifest: Resources/PrivacyInfo.xcprivacy
infoPlist: Resources/Info.plist
"""

@Test func generatesManifest() throws {
    let yaml = try XtoolManifest.yaml(config: ProjectConfig.parse(yaml: cfgYAML))
    #expect(yaml.hasPrefix(XtoolManifest.marker))
    #expect(yaml.contains("bundleID: app.example.helloship"))
    #expect(yaml.contains("product: HelloShip"))
    #expect(yaml.contains("infoPath: Resources/Info.plist"))
    #expect(yaml.contains("- Resources/PrivacyInfo.xcprivacy"))
    #expect(!yaml.contains("iconPath"))
}

@Test func refusesForeignXtoolYml() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xm-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "version: 1\nbundleID: x.y\n".write(to: dir.appendingPathComponent("xtool.yml"), atomically: true, encoding: .utf8)
    #expect(throws: XlessError.self) { try XtoolManifest.write(config: ProjectConfig.parse(yaml: cfgYAML), project: dir) }
}

@Test func overwritesOwnXtoolYml() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xm-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "\(XtoolManifest.marker)\nold".write(to: dir.appendingPathComponent("xtool.yml"), atomically: true, encoding: .utf8)
    try XtoolManifest.write(config: ProjectConfig.parse(yaml: cfgYAML), project: dir)
    #expect(try String(contentsOf: dir.appendingPathComponent("xtool.yml"), encoding: .utf8).contains("HelloShip"))
}
