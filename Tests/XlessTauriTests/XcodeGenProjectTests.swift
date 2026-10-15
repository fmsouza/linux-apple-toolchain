import Testing
import Foundation
@testable import XlessTauri
@testable import XlessCore

let fixturesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
func fixture(_ name: String) throws -> String { try String(contentsOf: fixturesDir.appendingPathComponent(name), encoding: .utf8) }

@Test func parsesHelloTauriProject() throws {
    let (name, t) = try XcodeGenProject.parse(yaml: fixture("project.yml"), file: "project.yml")
    #expect(name == "hello-tauri" && t.name == "hello-tauri_iOS")
    #expect(t.sources.map(\.path) == ["Sources", "Assets.xcassets", "Externals", "hello-tauri_iOS", "assets", "LaunchScreen.storyboard"])
    #expect(t.sources[4] == .init(path: "assets", buildPhase: "resources", type: "folder"))
    #expect(t.infoPath == "hello-tauri_iOS/Info.plist")
    #expect(t.entitlementsPath == "hello-tauri_iOS/hello-tauri_iOS.entitlements")
    #expect(t.deploymentTarget == "16.0")
    #expect(t.settings["PRODUCT_NAME"] == "HelloTauri")
    #expect(t.settings["ARCHS"] == "arm64")
    #expect(t.dependencies.first == .framework(path: "libapp.a", embed: false, codeSign: false))
    #expect(t.dependencies.contains(.sdk("WebKit.framework")) && t.dependencies.count == 8)
    #expect(t.preBuildScripts.count == 1 && t.preBuildScripts[0].name == "Build Rust Code")
    #expect(t.preBuildScripts[0].script.contains("tauri ios xcode-script"))
    #expect(t.postCompileScripts.isEmpty)
    #expect(t.infoProperties["UIRequiredDeviceCapabilities"] as? [String] == ["arm64", "metal"])
    #expect(t.infoProperties["LSRequiresIPhoneOS"] as? Bool == true)
}

@Test func parsesExtraFrameworkProject() throws {
    let (name, t) = try XcodeGenProject.parse(yaml: fixture("project-acme.yml"), file: "project.yml")
    #expect(name == "acme")
    #expect(t.dependencies.contains(.framework(path: "Pods/x/x.xcframework", embed: true, codeSign: true)))
    #expect(t.dependencies.contains(.framework(path: "libapp.a", embed: false, codeSign: false)))
    #expect(t.dependencies.filter { if case .sdk = $0 { true } else { false } }.count == 4)
    #expect(t.settings["LIBRARY_SEARCH_PATHS[arch=arm64]"] == "$(inherited) $(PROJECT_DIR)/Externals/arm64/$(CONFIGURATION)")
    #expect(t.settings["LIBRARY_SEARCH_PATHS[arch=x86_64]"]?.hasPrefix("$(inherited)") == true)
    #expect(t.settings["ENABLE_BITCODE"] == "false" && t.settings["PRODUCT_NAME"] == "Acme")
    #expect(t.postCompileScripts.map(\.name) == ["Patch Thing"])
    #expect(t.sources.contains(.init(path: "models", buildPhase: "resources", type: "folder")))
    #expect(t.infoProperties["UISupportedInterfaceOrientations"] as? [String] == ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft"])
    #expect(t.infoProperties["CFBundleShortVersionString"] as? String == "2.3.4")
    #expect(t.deploymentTarget == "15.0")
}

@Test func rejectsUnsupportedKeyWithLine() throws {
    let yaml = """
    name: x
    targets:
      app:
        type: application
        platform: iOS
        info: { path: Info.plist }
        postBuildScripts:
          - script: echo hi
    """
    do {
        _ = try XcodeGenProject.parse(yaml: yaml, file: "gen/apple/project.yml")
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.stage == .prepare)
        #expect(e.cause == "gen/apple/project.yml:7: unsupported project.yml key 'targets.app.postBuildScripts'")
        #expect(e.fix.contains("docs/tauri.md"))
    }
}

@Test func rejectsNestedUnsupportedKey() throws {
    let yaml = fixtureWithDependencyExtra
    do {
        _ = try XcodeGenProject.parse(yaml: yaml, file: "p.yml")
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.cause == "p.yml:8: unsupported project.yml key 'targets.app.dependencies[0].package'")
    }
}
private let fixtureWithDependencyExtra = """
name: x
targets:
  app:
    type: application
    platform: iOS
    info: { path: Info.plist }
    dependencies:
      - package: Foo
"""

@Test func rejectsTwoTargets() throws {
    let yaml = """
    name: x
    targets:
      a: { type: application, platform: iOS, info: { path: A.plist } }
      b: { type: application, platform: iOS, info: { path: B.plist } }
    """
    do {
        _ = try XcodeGenProject.parse(yaml: yaml, file: "p.yml")
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.stage == .prepare && e.cause.contains("exactly one"))
    }
}

@Test func rejectsNonIOSTarget() throws {
    let yaml = "name: x\ntargets:\n  a: { type: application, platform: macOS, info: { path: A.plist } }\n"
    #expect(throws: XlessError.self) { try XcodeGenProject.parse(yaml: yaml, file: "p.yml") }
}
