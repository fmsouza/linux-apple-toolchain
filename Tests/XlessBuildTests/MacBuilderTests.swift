import Testing
import Foundation
@testable import XlessBuild
@testable import XlessCore

let macYAML = """
bundleID: app.example.helloship
teamID: ABCDE12345
version: 1.0.0
build: 3
platforms:
  macos: { minimumOS: "14.0", product: HelloShip, distribution: developer-id }
"""

@Test func wrapperPackageMirrorsXtool() {
    let s = MacBuilder.wrapperPackage(product: "HelloShip", minimumOS: "14.0", rootRelativePath: "../..")
    #expect(s.contains(".macOS(\"14.0\")"))
    #expect(s.contains(".package(name: \"RootPackage\", path: \"../..\")"))
    #expect(s.contains(".executableTarget(name: \"HelloShipMac\""))
    #expect(s.contains("@executable_path/../Frameworks"))
}

@Test func baseInfoPlist() throws {
    let p = try MacBuilder.baseInfoPlist(config: ProjectConfig.parse(yaml: macYAML))
    #expect(p["CFBundleExecutable"] as? String == "HelloShip")
    #expect(p["CFBundleIdentifier"] as? String == "app.example.helloship")
    #expect(p["CFBundlePackageType"] as? String == "APPL")
    #expect(p["LSMinimumSystemVersion"] as? String == "14.0")
    #expect(p["CFBundleSupportedPlatforms"] as? [String] == ["MacOSX"])
    #expect(p["NSPrincipalClass"] as? String == "NSApplication")
}

@Test func builtExecutableSkipsDSYMCompanion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("xless-macbuilder-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let dwarf = root.appendingPathComponent("Release/HelloShipMac.dSYM/Contents/Resources/DWARF")
    try FileManager.default.createDirectory(at: dwarf, withIntermediateDirectories: true)
    try Data("dwarf".utf8).write(to: dwarf.appendingPathComponent("HelloShipMac"))
    #expect(MacBuilder.builtExecutable(named: "HelloShipMac", under: root) == nil)
    try Data("exe".utf8).write(to: root.appendingPathComponent("Release/HelloShipMac"))
    #expect(MacBuilder.builtExecutable(named: "HelloShipMac", under: root)?.resolvingSymlinksInPath().path
        == root.appendingPathComponent("Release/HelloShipMac").resolvingSymlinksInPath().path)
}

@Test func swiftBuildNamesTheProductWithTheAppSwiftToolchain() {
    // Ruling R10: SwiftPM 6.2's Swift Build builds only targets unless --product names the executable (as for Tauri's
    // Swift aggregate); the image's own SwiftPM keeps the invocation it always had.
    let w = URL(fileURLWithPath: "/p/.xless/macos-pkg"), t = URL(fileURLWithPath: "/sdk/toolset-swb.json")
    // It also selects one architecture by --swift-sdk and --arch: with --triple it builds arm64 and x86_64 and needs lipo.
    let base = ["build", "--package-path", "/p/.xless/macos-pkg", "--scratch-path", "/p/.xless/macos-build-x86_64-swift-6.2.3",
                "-c", "release", "--build-system", "swiftbuild"]
    let scratch = URL(fileURLWithPath: "/p/.xless/macos-build-x86_64-swift-6.2.3")
    #expect(MacBuilder.swiftBuildArguments(wrapper: w, scratch: scratch, arch: "x86_64", minimumOS: "14.0", toolset: t, product: "HelloShip",
                                           own: SwiftToolchain(version: "6.2.3", root: "/opt/xless/toolchains/swift-6.2.3"))
            == base + ["--swift-sdk", "x86_64-apple-macosx", "--arch", "x86_64", "--toolset", "/sdk/toolset-swb.json", "--product", "HelloShipMac"])
    #expect(MacBuilder.swiftBuildArguments(wrapper: w, scratch: scratch, arch: "x86_64", minimumOS: "14.0", toolset: t, product: "HelloShip",
                                           own: nil) == base + ["--triple", "x86_64-apple-macosx14.0", "--toolset", "/sdk/toolset-swb.json"])
}
