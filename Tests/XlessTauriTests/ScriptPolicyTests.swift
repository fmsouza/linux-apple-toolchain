import Testing
import Foundation
@testable import XlessTauri
@testable import XlessCore

private func overlay(_ extra: String = "") throws -> TauriOverlay {
    try TauriOverlay.parse(yaml: "type: tauri\nbundleID: com.example.acme\nteamID: ABCDE12345\n\(extra)", name: "acme")
}

@Suite struct ScriptPolicyTests {
    @Test func mapsBuiltInAndIgnoredScripts() throws {
        let (_, target) = try XcodeGenProject.parse(yaml: fixture("project-acme.yml"), file: "project.yml")
        let handling = try ScriptPolicy.check(target: target, overlay: overlay("scripts: { \"Patch Thing\": ignore }\n"))
        #expect(handling == ["Build Rust Code": "built-in", "Patch Thing": "ignore"])
    }

    @Test func refusesUnmappedScript() throws {
        let (_, target) = try XcodeGenProject.parse(yaml: fixture("project-acme.yml"), file: "project.yml")
        do {
            _ = try ScriptPolicy.check(target: target, overlay: overlay())
            Issue.record("unmapped script accepted")
        } catch let e as XlessError {
            #expect(e.stage == .prepare)
            #expect(e.cause == "project.yml script 'Patch Thing' is not handled")
            #expect(e.fix == "add scripts: { \"Patch Thing\": ignore } to the overlay if xless already covers it, or report it")
        }
    }

    @Test func classifyKeepsTheScriptText() throws {
        let (_, target) = try XcodeGenProject.parse(yaml: fixture("project-acme.yml"), file: "project.yml")
        let all = ScriptPolicy.classify(target: target, overlay: try overlay())
        #expect(all.first { $0.name == "Build Rust Code" }?.script.contains("pnpm tauri ios xcode-script") == true)
        #expect(all.first { $0.name == "Patch Thing" }.map { $0.handling == nil && $0.script == "echo patch" } == true)
    }

    @Test func helloTauriNeedsNoMapping() throws {
        let (_, target) = try XcodeGenProject.parse(yaml: fixture("project.yml"), file: "project.yml")
        #expect(try ScriptPolicy.check(target: target, overlay: overlay()) == ["Build Rust Code": "built-in"])
    }
}
