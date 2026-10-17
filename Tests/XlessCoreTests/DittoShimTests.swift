import Foundation
import Testing
@testable import XlessCore

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("ditto-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private let old = Date(timeIntervalSince1970: 1_577_840_460)   // 2020-01-01 01:01

@Test func dittoCopiesAFileFollowingLinksAndKeepingModeAndTime() throws {
    let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
    let fm = FileManager.default
    try fm.createDirectory(at: d.appendingPathComponent("a/sub"), withIntermediateDirectories: true)
    try Data("hi".utf8).write(to: d.appendingPathComponent("a/real.h"))
    try fm.setAttributes([.posixPermissions: 0o640, .modificationDate: old], ofItemAtPath: d.appendingPathComponent("a/real.h").path)
    try fm.createSymbolicLink(atPath: d.appendingPathComponent("a/sub/link.h").path, withDestinationPath: "../real.h")
    // CocoaPods: ditto "${PODS_ROOT}/Headers/Public/X/X.modulemap" "${BUILT_PRODUCTS_DIR}/X.modulemap" (a symlink source).
    try DittoShim.run([d.appendingPathComponent("a/sub/link.h").path, d.appendingPathComponent("out/deep/x.h").path])
    let out = d.appendingPathComponent("out/deep/x.h").path
    #expect(try fm.destinationOfSymbolicLinkIfAny(out) == nil)
    #expect(fm.contents(atPath: out) == Data("hi".utf8))
    let attrs = try fm.attributesOfItem(atPath: out)
    #expect((attrs[.posixPermissions] as? Int) == 0o640 && (attrs[.modificationDate] as? Date) == old)
    // Into an existing directory: named after the file the link resolves to (macOS ditto does the same).
    try fm.createDirectory(at: d.appendingPathComponent("dir"), withIntermediateDirectories: true)
    try DittoShim.run([d.appendingPathComponent("a/sub/link.h").path, d.appendingPathComponent("dir").path])
    #expect(try fm.contentsOfDirectory(atPath: d.appendingPathComponent("dir").path) == ["real.h"])
}

@Test func dittoMergesDirectoriesKeepingLinks() throws {
    let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
    let fm = FileManager.default
    try fm.createDirectory(at: d.appendingPathComponent("src/sub"), withIntermediateDirectories: true)
    try Data("1".utf8).write(to: d.appendingPathComponent("src/one"))
    try fm.createSymbolicLink(atPath: d.appendingPathComponent("src/sub/l").path, withDestinationPath: "../one")
    try fm.createDirectory(at: d.appendingPathComponent("dst"), withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: d.appendingPathComponent("dst/keep"))
    try Data("old".utf8).write(to: d.appendingPathComponent("dst/one"))
    try DittoShim.run([d.appendingPathComponent("src").path, d.appendingPathComponent("dst").path])
    #expect(try fm.contentsOfDirectory(atPath: d.appendingPathComponent("dst").path).sorted() == ["keep", "one", "sub"])
    #expect(fm.contents(atPath: d.appendingPathComponent("dst/one").path) == Data("1".utf8))
    #expect(try fm.destinationOfSymbolicLink(atPath: d.appendingPathComponent("dst/sub/l").path) == "../one")
}

@Test func dittoRefusesOptionsAndMultipleSources() {
    for args in [["-V", "a", "b"], ["--rsrc", "a", "b"], ["a", "b", "c"], ["a"]] {
        #expect(throws: DittoShim.Unsupported.self) { try DittoShim.run(args) }
    }
    #expect(throws: XlessError.self) { try DittoShim.run(["/nonexistent/x", "/tmp/y"]) }
}

private extension FileManager {
    func destinationOfSymbolicLinkIfAny(_ path: String) throws -> String? {
        (try attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink ? try destinationOfSymbolicLink(atPath: path) : nil
    }
}
