import Testing
import Foundation
import XlessMachO
import XlessCore
@testable import XlessTauri

/// Thin MH_MAGIC_64 with LC_BUILD_VERSION (iOS), LC_LOAD_DYLIB and LC_RPATH.
func machO(dylibs: [String], rpaths: [String], cpu: UInt32 = 0x0100000c, minos: UInt32 = 0x110000) -> Data {
    var d = Data(), cmds = Data()
    func u32(_ v: UInt32, _ to: inout Data) { var x = v.littleEndian; withUnsafeBytes(of: &x) { to.append(contentsOf: $0) } }
    u32(0x32, &cmds); u32(24, &cmds); u32(2, &cmds); u32(minos, &cmds); u32(0x1b0000, &cmds); u32(0, &cmds)
    func str(_ cmd: UInt32, _ name: String, dylib: Bool) {
        let off = dylib ? 24 : 12
        let size = (off + name.utf8.count + 1 + 7) & ~7
        u32(cmd, &cmds); u32(UInt32(size), &cmds); u32(UInt32(off), &cmds)
        if dylib { u32(2, &cmds); u32(0x10000, &cmds); u32(0x10000, &cmds) }
        cmds.append(contentsOf: Array(name.utf8)); cmds.append(Data(repeating: 0, count: size - off - name.utf8.count))
    }
    for l in dylibs { str(0xc, l, dylib: true) }
    for r in rpaths { str(0x8000001c, r, dylib: false) }
    u32(0xfeedfacf, &d); u32(cpu, &d); u32(0, &d); u32(2, &d)
    u32(UInt32(1 + dylibs.count + rpaths.count), &d); u32(UInt32(cmds.count), &d); u32(0, &d); u32(0, &d)
    return d + cmds
}

func makeApp(bundleID: String = "com.example.app", extraLib: String? = nil) throws -> URL {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("rep-\(UUID().uuidString).app")
    let fm = FileManager.default
    try fm.createDirectory(at: app.appendingPathComponent("Frameworks/x.framework"), withIntermediateDirectories: true)
    try fm.createDirectory(at: app.appendingPathComponent("_CodeSignature"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "app", "DTXcode": "2700", "CFBundleVersion": "1"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
    try machO(dylibs: ["/usr/lib/libSystem.B.dylib"] + (extraLib.map { [$0] } ?? []), rpaths: ["@executable_path/Frameworks"])
        .write(to: app.appendingPathComponent("app"))
    try machO(dylibs: ["/usr/lib/libSystem.B.dylib"], rpaths: []).write(to: app.appendingPathComponent("Frameworks/x.framework/x"))
    try Data("sig".utf8).write(to: app.appendingPathComponent("_CodeSignature/CodeResources"))
    try Data("p".utf8).write(to: app.appendingPathComponent("embedded.mobileprovision"))
    return app
}

@Test func reportsBundleContents() throws {
    let app = try makeApp(); defer { try? FileManager.default.removeItem(at: app) }
    let r = try BundleReport.make(app: app)
    #expect(r.files == ["Frameworks/x.framework/x", "Info.plist", "app"])
    #expect(r.infoPlist["DTXcode"] == nil && r.infoPlist["CFBundleVersion"] == nil)
    #expect(r.infoPlist["CFBundleIdentifier"] == "com.example.app")
    #expect(r.executable == ExecutableReport(platform: 2, minos: "17.0", linkedLibraries: ["/usr/lib/libSystem.B.dylib"], rpaths: ["@executable_path/Frameworks"]))
    #expect(r.frameworks["x.framework"]?.linkedLibraries == ["/usr/lib/libSystem.B.dylib"])
}

@Test func diffReportsAndAllows() throws {
    let a = try makeApp(bundleID: "com.example.a"), b = try makeApp(bundleID: "com.example.b", extraLib: "@rpath/y")
    defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    let ra = try BundleReport.make(app: a), rb = try BundleReport.make(app: b)
    #expect(BundleReport.diff(reference: ra, actual: ra, allowed: []).isEmpty)
    let d = BundleReport.diff(reference: ra, actual: rb, allowed: [])
    #expect(d.contains { $0.hasPrefix("plist:CFBundleIdentifier") })
    #expect(d.contains { $0.hasPrefix("lib:@rpath/y") })
    #expect(BundleReport.diff(reference: ra, actual: rb, allowed: ["plist:CFBundleIdentifier", "lib:@rpath/y"]).isEmpty)
}

@Test func reportRoundTripsJSON() throws {
    let app = try makeApp(); defer { try? FileManager.default.removeItem(at: app) }
    let r = try BundleReport.make(app: app)
    #expect(try JSONDecoder().decode(BundleReport.self, from: r.json()) == r)
    #expect(try r.json() == r.json())
}

@Test func missingBundleIsBuildError() {
    #expect { try BundleReport.make(app: URL(fileURLWithPath: "/nonexistent/x.app")) } throws: {
        ($0 as? XlessError)?.stage == .build
    }
}

@Test func parsesAllowFile() {
    #expect(BundleReport.parseAllow("# gap\n\nplist:A\n  file:b  \n") == ["plist:A", "file:b"])
}

private func roundTrip(_ plist: [String: Any]) throws -> [String: Any] {
    let d = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    return try PropertyListSerialization.propertyList(from: d, options: [], format: nil) as! [String: Any]
}

@Test func canonicalRendersNestedPlistValues() throws {
    let plist = try roundTrip([
        "v": [["b": true, "a": 3, "c": [false, "x\"y"], "d": Data([1, 2, 3]), "e": Date(timeIntervalSince1970: 86400), "f": 1.5] as [String: Any], 7, "s"] as [Any],
    ])
    #expect(BundleReport.canonical(plist["v"]!, top: true)
        == #"[{"a":3,"b":true,"c":[false,"x\"y"],"d":data(AQID),"e":date(1970-01-02T00:00:00Z),"f":1.5},7,"s"]"#)
    #expect(BundleReport.canonical(try roundTrip(["t": true])["t"]!, top: true) == "true")
    #expect(BundleReport.canonical(try roundTrip(["t": 1])["t"]!, top: true) == "1")
    #expect(BundleReport.canonical("plain", top: true) == "plain")
}

@Test func canonicalIsStableAcrossInsertionOrder() {
    var a: [String: Any] = [:], b: [String: Any] = [:]
    let keys = (0..<30).map { "k\($0)" }
    for k in keys { a[k] = [k: 1] as [String: Any] }
    for k in keys.reversed() { b[k] = [k: 1] as [String: Any] }
    #expect(BundleReport.canonical(a) == BundleReport.canonical(b))
    #expect(BundleReport.canonical(a) == BundleReport.canonical(a))
}

@Test func malformedFrameworkIsBuildError() throws {
    let app = try makeApp(); defer { try? FileManager.default.removeItem(at: app) }
    var bad = machO(dylibs: ["/usr/lib/libSystem.B.dylib"], rpaths: [])
    bad.removeLast(8)
    try bad.write(to: app.appendingPathComponent("Frameworks/x.framework/x"))
    #expect { try BundleReport.make(app: app) } throws: { ($0 as? XlessError)?.stage == .build }
}

@Test func staticArchiveFrameworkIsNotReported() throws {
    let app = try makeApp(); defer { try? FileManager.default.removeItem(at: app) }
    var slice = Data("!<arch>\n".utf8); slice.append(Data("x.o/            0           0     0     100644  4         `\nabcd".utf8))
    var fat = Data()
    func be(_ v: UInt32) { var x = v.bigEndian; withUnsafeBytes(of: &x) { fat.append(contentsOf: $0) } }
    be(0xcafebabe); be(1); be(0x0100000c); be(0); be(0x4000); be(UInt32(slice.count)); be(14)
    fat.append(Data(count: 0x4000 - fat.count)); fat.append(slice)
    try fat.write(to: app.appendingPathComponent("Frameworks/x.framework/x"))
    #expect(try BundleReport.make(app: app).frameworks.isEmpty)
}

private func fatApp(x86Libs: [String] = ["/usr/lib/libx86.dylib"], x86Minos: UInt32 = 0x0a0f00, thinX86: Bool = false) throws -> URL {
    let app = try makeApp()
    let arm = machO(dylibs: ["/usr/lib/libSystem.B.dylib", "/usr/lib/libarm.dylib"], rpaths: ["@executable_path/../Frameworks"], minos: 0x0b0000)
    let x86 = machO(dylibs: x86Libs, rpaths: [], cpu: 0x01000007, minos: x86Minos)
    try (thinX86 ? arm : MachO.makeFat([x86, arm])).write(to: app.appendingPathComponent("app"))
    return app
}

@Test func fatBinaryReportsPerArchitectureSlices() throws {
    let app = try fatApp(); defer { try? FileManager.default.removeItem(at: app) }
    let e = try BundleReport.make(app: app).executable
    #expect(e.slices?["arm64"] == SliceReport(platform: 2, minos: "11.0", linkedLibraries: ["/usr/lib/libSystem.B.dylib", "/usr/lib/libarm.dylib"], rpaths: ["@executable_path/../Frameworks"]))
    #expect(e.slices?["x86_64"] == SliceReport(platform: 2, minos: "10.15", linkedLibraries: ["/usr/lib/libx86.dylib"], rpaths: []))
    #expect(e.minos == "11.0" && e.linkedLibraries == e.slices?["arm64"]?.linkedLibraries && e.rpaths == ["@executable_path/../Frameworks"])
}

@Test func thinBinaryHasNoSlices() throws {
    let app = try makeApp(); defer { try? FileManager.default.removeItem(at: app) }
    let r = try BundleReport.make(app: app)
    #expect(r.executable.slices == nil)
    #expect(!String(decoding: try r.json(), as: UTF8.self).contains("slices"))
}

@Test func diffComparesSlicesPerArchitecture() throws {
    let full = try fatApp(), thinOnly = try fatApp(thinX86: true), other = try fatApp(x86Libs: ["/usr/lib/liby.dylib"], x86Minos: 0x0b0000)
    defer { for u in [full, thinOnly, other] { try? FileManager.default.removeItem(at: u) } }
    let rf = try BundleReport.make(app: full), rt = try BundleReport.make(app: thinOnly), ro = try BundleReport.make(app: other)
    #expect(BundleReport.diff(reference: rf, actual: rf, allowed: []).isEmpty)
    #expect(BundleReport.diff(reference: rf, actual: rt, allowed: []).contains { $0.hasPrefix("exe:slice:x86_64:missing") })
    let d = BundleReport.diff(reference: rf, actual: ro, allowed: [])
    #expect(d.contains { $0.hasPrefix("lib:x86_64:/usr/lib/liby.dylib") })
    #expect(d.contains { $0.hasPrefix("lib:x86_64:/usr/lib/libx86.dylib") })
    #expect(d.contains { $0.hasPrefix("exe:x86_64:minos") })
    #expect(!d.contains { $0.contains("arm64") })
}

@Test func committedIOSReferenceRoundTripsByteIdentically() throws {
    var dir = URL(fileURLWithPath: #filePath)
    while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { dir.deleteLastPathComponent() }
    let bytes = try Data(contentsOf: dir.appendingPathComponent("samples/HelloTauri/reference/reference.json"))
    let r = try JSONDecoder().decode(BundleReport.self, from: bytes)
    #expect(r.executable.slices == nil)
    #expect(try r.json() == bytes)
}

@Test func reportsMacOSBundleLayout() throws {
    let fm = FileManager.default
    let app = fm.temporaryDirectory.appendingPathComponent("rep-\(UUID().uuidString).app"); defer { try? fm.removeItem(at: app) }
    let c = app.appendingPathComponent("Contents")
    for d in ["MacOS", "Resources/resources", "Frameworks/x.framework", "_CodeSignature"] {
        try fm.createDirectory(at: c.appendingPathComponent(d), withIntermediateDirectories: true)
    }
    let plist: [String: Any] = ["CFBundleIdentifier": "com.example.mac", "CFBundleExecutable": "app", "CFBundleVersion": "1"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: c.appendingPathComponent("Info.plist"))
    let arm = machO(dylibs: ["/usr/lib/libSystem.B.dylib"], rpaths: ["@executable_path/../Frameworks"], minos: 0x0b0000)
    let x86 = machO(dylibs: ["/usr/lib/libSystem.B.dylib"], rpaths: ["@executable_path/../Frameworks"], cpu: 0x01000007, minos: 0x0b0000)
    try MachO.makeFat([x86, arm]).write(to: c.appendingPathComponent("MacOS/app"))
    try machO(dylibs: ["/usr/lib/libz.1.dylib"], rpaths: []).write(to: c.appendingPathComponent("Frameworks/x.framework/x"))
    try Data("hi".utf8).write(to: c.appendingPathComponent("Resources/resources/hello.txt"))
    try Data("sig".utf8).write(to: c.appendingPathComponent("_CodeSignature/CodeResources"))
    let r = try BundleReport.make(app: app)
    #expect(r.files == ["Contents/Frameworks/x.framework/x", "Contents/Info.plist", "Contents/MacOS/app", "Contents/Resources/resources/hello.txt"])
    #expect(r.infoPlist["CFBundleIdentifier"] == "com.example.mac")
    #expect(r.executable.slices?.keys.sorted() == ["arm64", "x86_64"])
    #expect(r.executable.rpaths == ["@executable_path/../Frameworks"])
    #expect(r.frameworks["x.framework"]?.linkedLibraries == ["/usr/lib/libz.1.dylib"])
}
