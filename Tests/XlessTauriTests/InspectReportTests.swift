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
