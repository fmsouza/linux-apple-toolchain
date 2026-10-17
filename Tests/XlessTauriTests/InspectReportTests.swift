import Testing
import Foundation
@testable import XlessTauri
@testable import XlessCore

private func source() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("inspect-\(UUID().uuidString)")
    let apple = root.appendingPathComponent("src-tauri/gen/apple")
    try FileManager.default.createDirectory(at: apple, withIntermediateDirectories: true)
    try fixture("project-acme.yml").write(to: apple.appendingPathComponent("project.yml"), atomically: true, encoding: .utf8)
    try #"{"productName":"Acme","version":"1.2.3","identifier":"com.example.acme","build":{"beforeBuildCommand":"node build.mjs","frontendDist":"../dist"}}"#
        .write(to: root.appendingPathComponent("src-tauri/tauri.conf.json"), atomically: true, encoding: .utf8)
    return root
}

private let inspectOverlayYAML = """
    type: tauri
    bundleID: com.example.acme
    teamID: ABCDE12345
    tauri: { features: [zeta, alpha] }
    linkFlags: [-ObjC]
    privacyManifest: /overlay/PrivacyInfo.xcprivacy
    binaryDependencies:
      - url: https://example.com/Zed.zip
        sha256: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        extract: Zed.xcframework
        to: src-tauri/gen/apple/Pods/Zed/Zed.xcframework
        linkFlags: [-lc++]
    """

@Suite struct InspectReportTests {
    @Test func goldenReport() throws {
        let overlay = try TauriOverlay.parse(yaml: inspectOverlayYAML, name: "acme")
        let r = try TauriProject.resolve(overlay: overlay, source: source())
        let scripts = InspectReport.scripts(target: r.target, overlay: overlay)
        let texts = InspectReport.builtInScripts(target: r.target, overlay: overlay)
        let text = InspectReport.make(resolved: r, overlay: overlay, contract: .init(tauri: "2.13.0", cli: "2.12.1"),
                                      scripts: scripts, scriptTexts: texts, swiftPackages: nil, nextBuild: nil)
        #expect(scripts["Patch Thing"] == "UNHANDLED" && scripts["Build Rust Code"] == "built-in")
        #expect(Array(texts.keys) == ["Build Rust Code"])
        let golden = try fixture("inspect-acme.golden.txt")
        #expect(text == golden)
    }

    @Test func discoveredPackagesAndNextBuild() throws {
        let overlay = try TauriOverlay.parse(yaml: inspectOverlayYAML + "\nbuild: 7\n", name: "acme")
        let r = try TauriProject.resolve(overlay: overlay, source: source())
        let text = InspectReport.make(resolved: r, overlay: overlay, contract: .init(tauri: "2.12.0", cli: "2.12.0"),
                                      scripts: [:], swiftPackages: ["tauri-plugin-b", "Tauri"], nextBuild: "8")
        #expect(text.contains("swiftPackages: Tauri, tauri-plugin-b\n"))
        #expect(text.contains("status: in contract\n") && text.contains("scheme: fixed\nnumber: 7\nnext: 8\n"))
        #expect(text.contains("[scripts]\n(none)\n"))
    }

    @Test func builtInScriptIsPrintedInFullWithTheNote() throws {
        let overlay = try TauriOverlay.parse(yaml: inspectOverlayYAML, name: "acme")
        let r = try TauriProject.resolve(overlay: overlay, source: source())
        let text = InspectReport.make(resolved: r, overlay: overlay, contract: .init(tauri: "2.12.0", cli: "2.12.0"),
                                      scripts: ["Build": "built-in", "Other": "ignore"],
                                      scriptTexts: ["Build": "./prepare.sh\npnpm tauri ios xcode-script -v\n"], swiftPackages: nil, nextBuild: nil)
        #expect(text.contains("""
            [scripts]
            Build: built-in (\(ScriptPolicy.builtInNote))
              | ./prepare.sh
              | pnpm tauri ios xcode-script -v
            Other: ignore

            """))
    }
}

@Suite struct InspectReportMacTests {
    private func macSource() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inspect-mac-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("src-tauri")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("res/sub"), withIntermediateDirectories: true)
        try "a".write(to: dir.appendingPathComponent("res/a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: dir.appendingPathComponent("res/sub/b.txt"), atomically: true, encoding: .utf8)
        try #"{"productName":"Acme","version":"1.2.3","identifier":"com.example.acme","build":{"frontendDist":"../dist"},"bundle":{"resources":["res/"],"fileAssociations":[{"ext":["acme"]},{"ext":["txt"]}],"macOS":{"minimumSystemVersion":"12.0"}}}"#
            .write(to: dir.appendingPathComponent("tauri.conf.json"), atomically: true, encoding: .utf8)
        return root
    }

    @Test func goldenMacReport() throws {
        let overlay = try TauriOverlay.parse(yaml: "type: tauri\nbundleID: com.example.acme\nteamID: ABCDE12345\n", name: "acme")
        let src = try macSource()
        let r = try TauriProject.resolveMac(overlay: overlay, source: src)
        let text = InspectReport.makeMac(resolved: r, overlay: overlay, contract: .init(tauri: "2.13.0", cli: "2.12.1"), source: src)
        #expect(text == (try fixture("inspect-acme-macos.golden.txt")))
    }

    /// The report shows the macOS features (`macos.features` replaces `tauri.features`) and the macOS Info.plist only.
    @Test func macFeaturesAndInfoPlist() throws {
        let src = try macSource()
        let base = "type: tauri\nbundleID: com.example.acme\nteamID: ABCDE12345\ntauri: { features: [ipad] }\ninfoPlist: ios/Info.plist\n"
        func lines(_ yaml: String) throws -> [Substring] {
            let o = try TauriOverlay.parse(yaml: yaml, name: "acme")
            return InspectReport.makeMac(resolved: try TauriProject.resolveMac(overlay: o, source: src), overlay: o, contract: .init(tauri: "2.12.0", cli: "2.12.1"), source: src)
                .split(separator: "\n")
        }
        let inherited = try lines(base)
        #expect(inherited.contains("features: ipad") && inherited.contains("infoPlist: (none)"))
        let own = try lines(base + "macos: { features: [], infoPlist: /abs/mac.plist }\n")
        #expect(own.contains("features: (none) (macos.features)") && own.contains("infoPlist: /abs/mac.plist"))
    }
}
