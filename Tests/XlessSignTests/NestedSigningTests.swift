import Testing
import Foundation
@testable import XlessSign
@testable import XlessCore

private func onPath(_ tool: String) -> Bool {
    (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains {
        FileManager.default.isExecutableFile(atPath: "\($0)/\(tool)")
    }
}

/// Smallest arm64 Mach-O that rcodesign accepts: a __TEXT segment with one section plus an empty __LINKEDIT.
private func miniMachO(filetype: UInt32) -> Data {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func name(_ s: String) { d.append(Data(s.utf8)); d.append(Data(count: 16 - s.utf8.count)) }
    let cmdsSize: UInt32 = (72 + 80) + 72
    u32(0xfeedfacf); u32(0x0100000c); u32(0); u32(filetype); u32(2); u32(cmdsSize); u32(0); u32(0)
    u32(0x19); u32(72 + 80); name("__TEXT"); u64(0); u64(0x4000); u64(0); u64(0x4000); u32(5); u32(5); u32(1); u32(0)
    name("__text"); name("__TEXT"); u64(0x1000); u64(4); u32(0x1000); u32(2); u32(0); u32(0); u32(0x80000400); u32(0); u32(0); u32(0)
    u32(0x19); u32(72); name("__LINKEDIT"); u64(0x4000); u64(0x4000); u64(0x4000); u64(0); u32(1); u32(1); u32(0); u32(0)
    d.append(Data(count: 0x4000 - d.count))
    return d
}

@Test(.enabled(if: onPath("rcodesign"))) func rcodesignSignsNestedFrameworks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nested-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("X.app", isDirectory: true)
    let fw = app.appendingPathComponent("Frameworks/x.framework", isDirectory: true)
    try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
    try Plist.write(["CFBundleExecutable": "X", "CFBundleIdentifier": "a.b"], to: app.appendingPathComponent("Info.plist"), stage: .sign)
    try Plist.write(["CFBundleExecutable": "x", "CFBundleIdentifier": "a.b.x"], to: fw.appendingPathComponent("Info.plist"), stage: .sign)
    try miniMachO(filetype: 2).write(to: app.appendingPathComponent("X"))
    try miniMachO(filetype: 6).write(to: fw.appendingPathComponent("x"))

    let key = try SigningKey.generate()
    let der = try selfSigned(key)
    let keyURL = root.appendingPathComponent("key.pem"), certURL = root.appendingPathComponent("cert.pem"), entURL = root.appendingPathComponent("ent.plist")
    try key.pem.write(to: keyURL, atomically: true, encoding: .utf8)
    try "-----BEGIN CERTIFICATE-----\n\(Data(der).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]))\n-----END CERTIFICATE-----\n"
        .write(to: certURL, atomically: true, encoding: .utf8)
    try Plist.write([String: Any](), to: entURL, format: .xml, stage: .sign)

    try Shell.run("rcodesign", RCodesign.signArguments(bundle: app, keyPEM: keyURL, certPEM: certURL, entitlements: entURL, distribution: .appStore), stage: .sign)
    try Shell.run("rcodesign", ["verify", app.appendingPathComponent("X").path], stage: .sign)
    #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("_CodeSignature/CodeResources").path))
    #expect(FileManager.default.fileExists(atPath: fw.appendingPathComponent("_CodeSignature/CodeResources").path))
    try Shell.run("rcodesign", ["verify", fw.appendingPathComponent("x").path], stage: .sign)
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

@Test(.enabled(if: onPath("rcodesign"))) func rcodesignSignsFrameworkWithStaticArchiveExecutable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nested-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("X.app", isDirectory: true)
    let fw = app.appendingPathComponent("Frameworks/x.framework", isDirectory: true)
    try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
    try Plist.write(["CFBundleExecutable": "X", "CFBundleIdentifier": "a.b"], to: app.appendingPathComponent("Info.plist"), stage: .sign)
    try Plist.write(["CFBundleExecutable": "x", "CFBundleIdentifier": "a.b.x"], to: fw.appendingPathComponent("Info.plist"), stage: .sign)
    try miniMachO(filetype: 2).write(to: app.appendingPathComponent("X"))
    try fatWrappedArchive().write(to: fw.appendingPathComponent("x"))

    let key = try SigningKey.generate()
    let der = try selfSigned(key)
    let keyURL = root.appendingPathComponent("key.pem"), certURL = root.appendingPathComponent("cert.pem"), entURL = root.appendingPathComponent("ent.plist")
    try key.pem.write(to: keyURL, atomically: true, encoding: .utf8)
    try "-----BEGIN CERTIFICATE-----\n\(Data(der).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]))\n-----END CERTIFICATE-----\n"
        .write(to: certURL, atomically: true, encoding: .utf8)
    try Plist.write([String: Any](), to: entURL, format: .xml, stage: .sign)

    // Known rcodesign 0.29.0 limitation: signing the framework panics ("index out of bounds" in macho_signing.rs) when its
    // executable is a fat-wrapped `ar` archive. withKnownIssue fails this test once rcodesign signs it, so the gap is revisited.
    withKnownIssue {
        try Shell.run("rcodesign", RCodesign.signArguments(bundle: app, keyPEM: keyURL, certPEM: certURL, entitlements: entURL, distribution: .appStore), stage: .sign)
    }
}
