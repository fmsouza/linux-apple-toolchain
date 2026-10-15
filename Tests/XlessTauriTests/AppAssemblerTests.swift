import Testing
import Foundation
@testable import XlessTauri
@testable import XlessCore

private var fm: FileManager { .default }

private func write(_ text: String, _ url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func plist(_ body: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \(body)
    </dict>
    </plist>
    """
}

private let projectYml = """
    name: demo
    options:
      deploymentTarget:
        iOS: 16.0
    targets:
      demo_iOS:
        type: application
        platform: iOS
        sources:
          - path: Sources
          - path: demo_iOS
          - path: assets
            buildPhase: resources
            type: folder
        info:
          path: demo_iOS/Info.plist
          properties:
            UIRequiredDeviceCapabilities: [arm64, metal]
            CFBundleVersion: "1.0.0"
        settings:
          base:
            PRODUCT_NAME: Demo
        dependencies:
          - framework: libapp.a
            embed: false
          - framework: Vendor/x.xcframework
            embed: true
          - sdk: UIKit.framework
    """

/// A work tree shaped like a Tauri app after cargo: project.yml, Info.plist with Xcode placeholders, Info.ios.plist,
/// an `assets/` folder reference and an xcframework with a device and a simulator slice.
private func workTree() throws -> URL {
    let work = fm.temporaryDirectory.appendingPathComponent("assemble-\(UUID().uuidString)", isDirectory: true)
    let apple = work.appendingPathComponent("src-tauri/gen/apple")
    try write(projectYml, apple.appendingPathComponent("project.yml"))
    try write(#"{"productName":"Demo","version":"1.2.3","identifier":"com.example.demo"}"#, work.appendingPathComponent("src-tauri/tauri.conf.json"))
    try write(plist("""
        <key>CFBundleDevelopmentRegion</key><string>$(DEVELOPMENT_LANGUAGE)</string>
        <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
        <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
        <key>CFBundleName</key><string>$(PRODUCT_NAME)</string>
        <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
        <key>CFBundleVersion</key><string>1.0.0</string>
        <key>LSRequiresIPhoneOS</key><true/>
        """), apple.appendingPathComponent("demo_iOS/Info.plist"))
    try write(plist("""
        <key>UIApplicationSceneManifest</key>
        <dict><key>UIApplicationSupportsMultipleScenes</key><true/><key>UISceneConfigurations</key><dict/></dict>
        """), work.appendingPathComponent("src-tauri/Info.ios.plist"))
    try write("b\n", apple.appendingPathComponent("assets/a/b.txt"))
    let xc = apple.appendingPathComponent("Vendor/x.xcframework")
    try fm.createDirectory(at: xc.appendingPathComponent("ios-arm64/x.framework"), withIntermediateDirectories: true)
    try (Data([0xcf, 0xfa, 0xed, 0xfe]) + Data("device".utf8)).write(to: xc.appendingPathComponent("ios-arm64/x.framework/x"))   // MH_MAGIC_64
    try write(plist("<key>CFBundleExecutable</key><string>x</string>"), xc.appendingPathComponent("ios-arm64/x.framework/Info.plist"))
    try write("// header", xc.appendingPathComponent("ios-arm64/x.framework/Headers/x.h"))
    try write("sim", xc.appendingPathComponent("ios-arm64_x86_64-simulator/x.framework/x"))
    return work
}

@Suite struct AppAssemblerTests {
    @Test func assemblesTheApp() throws {
        let work = try workTree()
        let privacy = fm.temporaryDirectory.appendingPathComponent("privacy-\(UUID().uuidString)/PrivacyInfo.xcprivacy")
        try write(plist("<key>NSPrivacyTracking</key><false/>"), privacy)
        let overlay = try TauriOverlay.parse(yaml: "type: tauri\nbundleID: com.example.demo.linux\nteamID: ABCDE12345\nbuild: 42\nprivacyManifest: \(privacy.path)\n", name: "demo")
        let resolved = try TauriProject.resolve(overlay: overlay, source: work)
        #expect(resolved.config.privacyManifest == privacy.path)
        let exe = work.appendingPathComponent(".xless/link/Demo")
        try write("exe", exe)
        let out = work.appendingPathComponent("out", isDirectory: true)
        let app = try AppAssembler.assemble(resolved: resolved, workRoot: work, executable: exe, into: out, note: { _ in })

        #expect(app.lastPathComponent == "Demo.app")
        #expect(fm.isExecutableFile(atPath: app.appendingPathComponent("Demo").path))
        #expect(try String(contentsOf: app.appendingPathComponent("PkgInfo"), encoding: .utf8) == "APPL????")
        #expect(try Data(contentsOf: app.appendingPathComponent("PrivacyInfo.xcprivacy")) == Data(contentsOf: privacy))

        let info = try Plist.read(app.appendingPathComponent("Info.plist"), stage: .build)
        #expect(info["CFBundleIdentifier"] as? String == "com.example.demo.linux")
        #expect(info["CFBundleExecutable"] as? String == "Demo")
        #expect(info["CFBundleName"] as? String == "Demo")
        #expect(info["CFBundleDevelopmentRegion"] as? String == "en")
        #expect(info["CFBundleShortVersionString"] as? String == "1.2.3")
        #expect(info["CFBundleVersion"] as? String == "42")
        #expect(info["CFBundlePackageType"] as? String == "APPL")
        #expect(info["CFBundleInfoDictionaryVersion"] as? String == "6.0")
        #expect(info["LSRequiresIPhoneOS"] as? Bool == true)
        #expect(info["UIRequiredDeviceCapabilities"] as? [String] == ["arm64", "metal"])
        let scenes = info["UIApplicationSceneManifest"] as? [String: Any]
        #expect(scenes?["UIApplicationSupportsMultipleScenes"] as? Bool == true)
        #expect(info["MinimumOSVersion"] as? String == "16.0")
        #expect(info["CFBundleSupportedPlatforms"] as? [String] == ["iPhoneOS"])
        #expect((info["UIDeviceFamily"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } == [1, 2])

        #expect(try String(contentsOf: app.appendingPathComponent("assets/a/b.txt"), encoding: .utf8) == "b\n")
        #expect(fm.fileExists(atPath: app.appendingPathComponent("Frameworks/x.framework/x").path))
        #expect(try Data(contentsOf: app.appendingPathComponent("Frameworks/x.framework/x")).suffix(6) == Data("device".utf8))
        #expect(!fm.fileExists(atPath: app.appendingPathComponent("Frameworks/x.framework/Headers").path))
        let all = (fm.enumerator(atPath: app.path)?.allObjects as? [String]) ?? []
        #expect(!all.contains { $0.contains("simulator") })
        #expect(!all.contains { $0.contains("libapp") })
    }

    @Test func refusesMissingPrivacyManifest() throws {
        let work = try workTree()
        let overlay = try TauriOverlay.parse(yaml: "type: tauri\nbundleID: com.example.demo\nteamID: ABCDE12345\nprivacyManifest: /nonexistent/PrivacyInfo.xcprivacy\n", name: "demo")
        let exe = work.appendingPathComponent(".xless/link/Demo")
        try write("exe", exe)
        #expect(throws: XlessError.self) {
            try AppAssembler.assemble(resolved: TauriProject.resolve(overlay: overlay, source: work), workRoot: work, executable: exe,
                                      into: work.appendingPathComponent("out", isDirectory: true), note: { _ in })
        }
    }

    @Test func infoIOSPlistMergesDeep() {
        let base: [String: Any] = ["A": ["x": 1, "y": 2], "B": "b"]
        let merged = AppAssembler.deepMerge(base, ["A": ["y": 3, "z": 4], "C": "c"])
        #expect(merged["A"] as? [String: Int] == ["x": 1, "y": 3, "z": 4])
        #expect(merged["B"] as? String == "b" && merged["C"] as? String == "c")
    }

    @Test func picksTheDeviceSlice() throws {
        let xc = fm.temporaryDirectory.appendingPathComponent("slices-\(UUID().uuidString)/y.xcframework", isDirectory: true)
        try fm.createDirectory(at: xc.appendingPathComponent("ios-arm64_armv7"), withIntermediateDirectories: true)
        try fm.createDirectory(at: xc.appendingPathComponent("ios-arm64_x86_64-simulator"), withIntermediateDirectories: true)
        let info: [String: Any] = ["AvailableLibraries": [
            ["LibraryIdentifier": "ios-arm64_x86_64-simulator", "SupportedPlatform": "ios", "SupportedPlatformVariant": "simulator"],
            ["LibraryIdentifier": "ios-arm64_armv7", "SupportedPlatform": "ios"],
        ]]
        try Plist.write(info, to: xc.appendingPathComponent("Info.plist"), format: .xml, stage: .build)
        #expect(AppAssembler.deviceSlice(of: xc)?.lastPathComponent == "ios-arm64_armv7")
        let bare = fm.temporaryDirectory.appendingPathComponent("slices-\(UUID().uuidString)/z.xcframework", isDirectory: true)
        try fm.createDirectory(at: bare.appendingPathComponent("ios-arm64"), withIntermediateDirectories: true)
        #expect(AppAssembler.deviceSlice(of: bare)?.lastPathComponent == "ios-arm64")
    }

    @Test func staticArchiveFrameworkIsLinkedNotEmbedded() throws {
        let work = try workTree()
        var ar = Data("!<arch>\n".utf8)
        ar.append(Data("x.o/".padding(toLength: 16, withPad: " ", startingAt: 0).utf8))
        try fm.removeItem(at: work.appendingPathComponent("src-tauri/gen/apple/Vendor/x.xcframework/ios-arm64/x.framework/x"))
        try ar.write(to: work.appendingPathComponent("src-tauri/gen/apple/Vendor/x.xcframework/ios-arm64/x.framework/x"))
        let overlay = try TauriOverlay.parse(yaml: "type: tauri\nbundleID: com.example.demo.linux\nteamID: ABCDE12345\nbuild: 42\n", name: "demo")
        let resolved = try TauriProject.resolve(overlay: overlay, source: work)
        let exe = work.appendingPathComponent(".xless/link/Demo")
        try write("exe", exe)
        nonisolated(unsafe) var notes: [String] = []
        let app = try AppAssembler.assemble(resolved: resolved, workRoot: work, executable: exe,
                                            into: work.appendingPathComponent("out", isDirectory: true), note: { notes.append($0) })
        #expect(!fm.fileExists(atPath: app.appendingPathComponent("Frameworks/x.framework").path))
        #expect(notes == ["note: x.framework is a static library; linked, not embedded"])
    }
}
