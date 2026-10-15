import Testing
import Foundation
@testable import XlessFinalize
@testable import XlessCore
@testable import XlessMachO

func thinBinary(platform: UInt32, minos: String, sdk: String) throws -> Data {
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    u32(0xfeedfacf); u32(0x0100000c); u32(0); u32(2); u32(1); u32(24); u32(0); u32(0)
    u32(0x32); u32(24); u32(platform); u32(try MachO.encodeVersion(minos)); u32(try MachO.encodeVersion(sdk)); u32(0)
    return d
}

func iosApp(minos: String = "17.0", extraFiles: [String: Data] = [:],
            plist: [String: Any] = ["CFBundleExecutable": "X", "ITSAppUsesNonExemptEncryption": false]) throws -> URL {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("fin-\(UUID())/X.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try Plist.write(plist, to: app.appendingPathComponent("Info.plist"), stage: .finalize)
    try thinBinary(platform: 2, minos: minos, sdk: minos).write(to: app.appendingPathComponent("X"))
    try Data().write(to: app.appendingPathComponent("PrivacyInfo.xcprivacy"))
    for (path, data) in extraFiles {
        let u = app.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
    }
    return app
}

let privacyLine = "privacyManifest: PrivacyInfo.xcprivacy"

@Test func patchesSDKAndStamps() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try Finalizer.run(input: iosApp(), outputDir: out, platform: .ios, config: config(privacyLine), meta: meta)
    let bv = try MachO.buildVersions(in: Data(contentsOf: app.appendingPathComponent("X")))
    #expect(bv.first?.sdk == 0x1b0000)
    #expect(bv.first?.minos == 0x110000)
    #expect(try Plist.read(app.appendingPathComponent("Info.plist"), stage: .finalize)["DTXcode"] as? String == "2700")
}

@Test func deploymentTargetMismatchFails() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    do { _ = try Finalizer.run(input: iosApp(minos: "16.0"), outputDir: out, platform: .ios, config: config(privacyLine), meta: meta); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .finalize)
        #expect(e.description.contains("16.0") && e.description.contains("17.0") && e.description.contains("Package.swift"))
    }
}

@Test func wrongPlatformBinaryFails() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try iosApp(extraFiles: ["Frameworks/Y.framework/Y": thinBinary(platform: 1, minos: "14.0", sdk: "14.0")])
    #expect(throws: XlessError.self) { try Finalizer.run(input: app, outputDir: out, platform: .ios, config: config(privacyLine), meta: meta) }
}

@Test func looseDylibFails() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try iosApp(extraFiles: ["Frameworks/libFoo.dylib": thinBinary(platform: 2, minos: "17.0", sdk: "17.0")])
    do { _ = try Finalizer.run(input: app, outputDir: out, platform: .ios, config: config(privacyLine), meta: meta); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.description.contains("libFoo.dylib")) }
}

@Test func missingPrivacyManifestFailsForAppStore() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    #expect(throws: XlessError.self) { try Finalizer.run(input: iosApp(), outputDir: out, platform: .ios, config: config(), meta: meta) }
}

@Test func oldSDKFails() throws {
    var old = meta
    old.platforms["iphoneos"]!.sdkVersion = "18.0"
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    #expect(throws: XlessError.self) { try Finalizer.run(input: iosApp(), outputDir: out, platform: .ios, config: config(privacyLine), meta: old) }
}

func noBuildVersionBinary() -> Data {
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    u32(0xfeedfacf); u32(0x0100000c); u32(0); u32(2); u32(0); u32(0); u32(0); u32(0)
    return d
}

@Test func machOWithoutBuildVersionFails() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try iosApp(extraFiles: ["Frameworks/Legacy.framework/Legacy": noBuildVersionBinary()])
    do { _ = try Finalizer.run(input: app, outputDir: out, platform: .ios, config: config(privacyLine), meta: meta); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .finalize)
        #expect(e.description.contains("Legacy.framework/Legacy") && e.description.contains("LC_BUILD_VERSION"))
    }
}

@Test func nestedFrameworkIsPatched() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try iosApp(extraFiles: ["Frameworks/Y.framework/Y": thinBinary(platform: 2, minos: "17.0", sdk: "17.0")])
    let result = try Finalizer.run(input: app, outputDir: out, platform: .ios, config: config(privacyLine), meta: meta)
    let bv = try MachO.buildVersions(in: Data(contentsOf: result.appendingPathComponent("Frameworks/Y.framework/Y")))
    #expect(bv.first?.sdk == 0x1b0000)
}

@Test func inputBundleIsUnchanged() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try iosApp()
    _ = try Finalizer.run(input: app, outputDir: out, platform: .ios, config: config(privacyLine), meta: meta)
    let bv = try MachO.buildVersions(in: Data(contentsOf: app.appendingPathComponent("X")))
    #expect(bv.first?.sdk == 0x110000)
    #expect(try Plist.read(app.appendingPathComponent("Info.plist"), stage: .finalize)["DTXcode"] == nil)
}

@Test func macOSUniversalHappyPath() throws {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("fin-\(UUID())/X.app")
    let macos = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
    try Plist.write(["CFBundleExecutable": "X"], to: app.appendingPathComponent("Contents/Info.plist"), stage: .finalize)
    let thin = try thinBinary(platform: 1, minos: "14.0", sdk: "14.0")
    try MachO.makeFat([thin, thin]).write(to: macos.appendingPathComponent("X"))
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let cfg = try config()
    let result = try Finalizer.run(input: app, outputDir: out, platform: .macos, config: cfg, meta: meta)
    let bv = try MachO.buildVersions(in: Data(contentsOf: result.appendingPathComponent("Contents/MacOS/X")))
    #expect(bv.count == 2)
    #expect(bv.allSatisfy { $0.sdk == 0x1b0000 && $0.minos == 0xe0000 })
    let info = try Plist.read(result.appendingPathComponent("Contents/Info.plist"), stage: .finalize)
    #expect(info["LSMinimumSystemVersion"] as? String == "14.0")
}

@Test func writesPkgInfoLikeXcode() throws {
    // Xcode 27.0 puts PkgInfo ("APPL????") in iOS app bundles too; xtool does not.
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try Finalizer.run(input: iosApp(), outputDir: out, platform: .ios, config: config(privacyLine), meta: meta)
    #expect(try Data(contentsOf: app.appendingPathComponent("PkgInfo")) == Data("APPL????".utf8))
}

@Test func finalizeFailureLeavesNoBundleInFinal() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())/final")
    try FileManager.default.createDirectory(at: out.appendingPathComponent("X.app"), withIntermediateDirectories: true)   // stale output
    #expect(throws: XlessError.self) {
        try Finalizer.run(input: iosApp(minos: "16.0"), outputDir: out, platform: .ios, config: config(privacyLine), meta: meta)
    }
    #expect(throws: XlessError.self) { try StagePaths(project: out, platform: .ios).bundle(in: out, stage: .sign) }
    #expect(!FileManager.default.fileExists(atPath: out.path + ".partial"))
}

// MARK: export compliance (ITSAppUsesNonExemptEncryption)

@Test func appStoreBuildWithoutComplianceKeyIsRefused() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try iosApp(plist: ["CFBundleExecutable": "X"])
    do { _ = try Finalizer.run(input: app, outputDir: out, platform: .ios, config: config(privacyLine), meta: meta); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .finalize)
        #expect(e.cause.contains("ITSAppUsesNonExemptEncryption"))
        #expect(e.fix.contains("usesNonExemptEncryption: false") && e.fix.contains("infoPlist"))
    }
}

@Test func configKeyStampsComplianceKey() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try Finalizer.run(input: iosApp(plist: ["CFBundleExecutable": "X"]), outputDir: out, platform: .ios,
                                config: config(privacyLine + "\nusesNonExemptEncryption: false"), meta: meta)
    #expect(try Plist.read(app.appendingPathComponent("Info.plist"), stage: .finalize)["ITSAppUsesNonExemptEncryption"] as? Bool == false)
}

@Test func configKeyTrueIsStampedToo() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try Finalizer.run(input: iosApp(plist: ["CFBundleExecutable": "X"]), outputDir: out, platform: .ios,
                                config: config(privacyLine + "\nusesNonExemptEncryption: true"), meta: meta)
    #expect(try Plist.read(app.appendingPathComponent("Info.plist"), stage: .finalize)["ITSAppUsesNonExemptEncryption"] as? Bool == true)
}

@Test func userPlistValueIsKeptWhenConfigAgrees() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try Finalizer.run(input: iosApp(plist: ["CFBundleExecutable": "X", "ITSAppUsesNonExemptEncryption": true]), outputDir: out, platform: .ios,
                                config: config(privacyLine + "\nusesNonExemptEncryption: true"), meta: meta)
    #expect(try Plist.read(app.appendingPathComponent("Info.plist"), stage: .finalize)["ITSAppUsesNonExemptEncryption"] as? Bool == true)
}

@Test func conflictingPlistAndConfigValuesAreRefused() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try iosApp(plist: ["CFBundleExecutable": "X", "ITSAppUsesNonExemptEncryption": true])
    do { _ = try Finalizer.run(input: app, outputDir: out, platform: .ios, config: config(privacyLine + "\nusesNonExemptEncryption: false"), meta: meta); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .finalize)
        #expect(e.cause.contains("ITSAppUsesNonExemptEncryption") && e.cause.contains("usesNonExemptEncryption"))
    }
}

@Test func macOSDeveloperIDDoesNotNeedComplianceKey() throws {
    // macos fixture in macOSUniversalHappyPath has no key and must keep passing.
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("fin-\(UUID())/X.app")
    let macos = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
    try Plist.write(["CFBundleExecutable": "X"], to: app.appendingPathComponent("Contents/Info.plist"), stage: .finalize)
    try thinBinary(platform: 1, minos: "14.0", sdk: "14.0").write(to: macos.appendingPathComponent("X"))
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    _ = try Finalizer.run(input: app, outputDir: out, platform: .macos, config: config(), meta: meta)
}

@Test func nonBooleanComplianceKeyInUserPlistIsRefused() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try iosApp(plist: ["CFBundleExecutable": "X", "ITSAppUsesNonExemptEncryption": "NO"])
    do { _ = try Finalizer.run(input: app, outputDir: out, platform: .ios, config: config(privacyLine), meta: meta); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .finalize && e.cause.contains("not a boolean")) }
}

/// Fat (cafebabe) wrapper with one arm64 slice that is an `ar` static archive, as shipped by the onnxruntime-c pod.
func fatWrappedArchive() -> Data {
    var slice = Data("!<arch>\n".utf8)
    slice.append(Data("x.o/            0           0     0     100644  4         `\nabcd".utf8))
    var d = Data()
    func be(_ v: UInt32) { var x = v.bigEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    be(0xcafebabe); be(1); be(0x0100000c); be(0); be(0x4000); be(UInt32(slice.count)); be(14)
    d.append(Data(count: 0x4000 - d.count)); d.append(slice)
    return d
}

@Test func staticArchiveFrameworkBinaryIsLeftAlone() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let archive = fatWrappedArchive()
    let app = try iosApp(extraFiles: ["Frameworks/x.framework/x": archive])
    let result = try Finalizer.run(input: app, outputDir: out, platform: .ios, config: config(privacyLine), meta: meta)
    #expect(try Data(contentsOf: result.appendingPathComponent("Frameworks/x.framework/x")) == archive)
    #expect(try MachO.buildVersions(in: Data(contentsOf: result.appendingPathComponent("X"))).first?.sdk == 0x1b0000)
}
