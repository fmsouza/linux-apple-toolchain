import Testing
import Foundation
@testable import XlessAssets
@testable import XlessCore

func fakePNG(_ w: UInt32, colorType: UInt8) -> Data {
    var d = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    func be(_ v: UInt32) { var x = v.bigEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    be(13); d.append(contentsOf: Array("IHDR".utf8)); be(w); be(w); d.append(contentsOf: [8, colorType, 0, 0, 0]); be(0)
    return d
}

func catalog(icon: Data) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cat-\(UUID()).xcassets")
    let set = root.appendingPathComponent("AppIcon.appiconset")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8).write(to: root.appendingPathComponent("Contents.json"))
    try Data(#"{"images":[{"filename":"i.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}"#.utf8)
        .write(to: set.appendingPathComponent("Contents.json"))
    try icon.write(to: set.appendingPathComponent("i.png"))
    return root
}

@Test func findsAppIconPNGs() throws {
    let pngs = try AssetsStage.appIconPNGs(catalog: catalog(icon: fakePNG(1024, colorType: 2)))
    #expect(pngs.count == 1)
}

@Test func rejectsAlphaIcon() throws {
    let pngs = try AssetsStage.appIconPNGs(catalog: catalog(icon: fakePNG(1024, colorType: 6)))
    do { try AssetsStage.checkIconsOpaque(pngs); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .assets); #expect(e.description.contains("alpha")) }
}

@Test func macOSWritesICNSAndPlistKey() async throws {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("in-\(UUID())/X.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
    try Plist.write(["CFBundleExecutable": "X"], to: app.appendingPathComponent("Contents/Info.plist"), stage: .assets)
    let cat = try catalog(icon: fakePNG(1024, colorType: 2))
    let yaml = """
    bundleID: a.b
    teamID: ABCDE12345
    version: "1"
    build: 1
    platforms:
      macos: { minimumOS: "14.0", product: X }
    assets: \(cat.path)
    """
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID())")
    let result = try await AssetsStage.run(input: app, outputDir: out, platform: .macos,
                                           config: ProjectConfig.parse(yaml: yaml), project: URL(fileURLWithPath: "/"))
    #expect(FileManager.default.fileExists(atPath: result.appendingPathComponent("Contents/Resources/AppIcon.icns").path))
    #expect(try Plist.read(result.appendingPathComponent("Contents/Info.plist"), stage: .assets)["CFBundleIconFile"] as? String == "AppIcon")
}

@Test func noCatalogJustCopies() async throws {
    // Developer ID (macOS) builds may ship without an icon.
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("in-\(UUID())/Y.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    let yaml = "bundleID: a.b\nteamID: ABCDE12345\nversion: \"1\"\nbuild: 1\nplatforms:\n  macos: { minimumOS: \"14.0\", product: Y }\n"
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID())")
    let r = try await AssetsStage.run(input: app, outputDir: out, platform: .macos, config: ProjectConfig.parse(yaml: yaml), project: URL(fileURLWithPath: "/"))
    #expect(r.lastPathComponent == "Y.app")
}

private func iosAssetsRun(assetsLine: String) async throws {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("in-\(UUID())/Y.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try Plist.write(["CFBundleExecutable": "Y"], to: app.appendingPathComponent("Info.plist"), stage: .assets)
    let yaml = "bundleID: a.b\nteamID: ABCDE12345\nversion: \"1\"\nbuild: 1\nplatforms:\n  ios: { minimumOS: \"17.0\", product: Y }\n\(assetsLine)"
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID())")
    _ = try await AssetsStage.run(input: app, outputDir: out, platform: .ios, config: ProjectConfig.parse(yaml: yaml), project: URL(fileURLWithPath: "/"))
}

@Test func appStoreBuildWithoutAssetsFails() async throws {
    do { try await iosAssetsRun(assetsLine: ""); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .assets)
        #expect(e.cause.contains("app icon"))
        #expect(e.fix.contains("AppIcon.appiconset") && e.fix.contains("assets:"))
    }
}

@Test func appStoreCatalogWithoutAppIconSetFails() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cat-\(UUID()).xcassets")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Accent.colorset"), withIntermediateDirectories: true)
    try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8).write(to: root.appendingPathComponent("Contents.json"))
    do { try await iosAssetsRun(assetsLine: "assets: \(root.path)\n"); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .assets); #expect(e.cause.contains("app icon")) }
}

@Test func normalizeAddsMissingScale() throws {
    let src = Data(#"{"images":[{"filename":"a.png","idiom":"universal","size":"1024x1024"}],"info":{"version":1}}"#.utf8)
    let out = try JSONSerialization.jsonObject(with: AssetsStage.normalizedAppIconContents(src)) as! [String: Any]
    #expect(((out["images"] as! [[String: Any]])[0]["scale"] as? String) == "1x")
}

@Test func normalizeKeepsExistingScale() throws {
    let src = Data(#"{"images":[{"filename":"a.png","idiom":"iphone","scale":"3x","size":"60x60"}],"info":{"version":1}}"#.utf8)
    let out = try JSONSerialization.jsonObject(with: AssetsStage.normalizedAppIconContents(src)) as! [String: Any]
    #expect(((out["images"] as! [[String: Any]])[0]["scale"] as? String) == "3x")
}

@Test func assetsFailureLeavesNoBundle() async throws {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("in-\(UUID())/X.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try Plist.write(["CFBundleExecutable": "X"], to: app.appendingPathComponent("Info.plist"), stage: .assets)
    let cat = try catalog(icon: fakePNG(1024, colorType: 6))   // alpha → ITMS-90717 → assets fails after copying
    let yaml = "bundleID: a.b\nteamID: ABCDE12345\nversion: \"1\"\nbuild: 1\nplatforms:\n  ios: { minimumOS: \"17.0\", product: X }\nassets: \(cat.path)\n"
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID())/assets")
    await #expect(throws: XlessError.self) {
        _ = try await AssetsStage.run(input: app, outputDir: out, platform: .ios, config: ProjectConfig.parse(yaml: yaml), project: URL(fileURLWithPath: "/"))
    }
    let left = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
    #expect(!left.contains { $0.hasSuffix(".app") })
    #expect(!FileManager.default.fileExists(atPath: out.path + ".partial"))
}
