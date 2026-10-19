import Testing
import Foundation
import Crypto
@testable import XlessSDK
@testable import XlessCore

private func tempDir(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcode-source-\(name)-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.resolvingSymlinksInPath()
}

/// Bytes standing in for an Xcode .xip (not Apple's file); the table entry is their own SHA-256.
private let fakeXipBytes = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
private let fakeXipHash = SHA256.hash(data: fakeXipBytes).map { String(format: "%02x", $0) }.joined()

private let known = [
    KnownXcode(build: "17C52", shortVersion: "26.2", appleSwift: "6.2.3", buildMachineOSBuild: "26A434", xipSHA256: []),
    KnownXcode(build: "27A266a", shortVersion: "27.0", appleSwift: "6.4", buildMachineOSBuild: "26A434", xipSHA256: ["00ff", fakeXipHash]),
]

private func fakeApp(_ dir: URL, name: String, build: String) throws -> URL {
    let app = dir.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleShortVersionString": "27.0", "ProductBuildVersion": build]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/version.plist"))
    return app
}

@Test func xipIsIdentifiedByContentWhateverItsNameAndPathSpelling() throws {
    let dir = try tempDir("xip with spaces")
    let xip = dir.appendingPathComponent("My Xcode copy.xip")
    try fakeXipBytes.write(to: xip)

    // Absolute path with spaces.
    let a = try XcodeSource.identify(path: xip.path, known: known, cwd: URL(fileURLWithPath: "/"), home: URL(fileURLWithPath: "/nonexistent"))
    #expect(a.xcode.build == "27A266a")
    #expect(a.kind == .xip)
    #expect(a.url.resolvingSymlinksInPath().path == xip.path)

    // ~/…: the home is the temp dir's parent.
    let home = dir.deletingLastPathComponent()
    let b = try XcodeSource.identify(path: "~/\(dir.lastPathComponent)/My Xcode copy.xip", known: known,
                                     cwd: URL(fileURLWithPath: "/"), home: home)
    #expect(b.xcode.build == "27A266a")
    #expect(b.url.resolvingSymlinksInPath().path == xip.path)

    // Relative to the working directory.
    let c = try XcodeSource.identify(path: "./My Xcode copy.xip", known: known, cwd: dir, home: home)
    #expect(c.xcode.build == "27A266a")
    #expect(c.url.resolvingSymlinksInPath().path == xip.path)
    let d = try XcodeSource.identify(path: "My Xcode copy.xip", known: known, cwd: dir, home: home)
    #expect(d.url.path == c.url.path)

    // A renamed .xip, no extension at all.
    let renamed = dir.appendingPathComponent("Xcode_27")
    try fakeXipBytes.write(to: renamed)
    #expect(try XcodeSource.identify(path: renamed.path, known: known, cwd: dir, home: home).kind == .xip)
}

@Test func aOneByteDifferentXipIsNotSupportedAndTheErrorListsBothReleases() throws {
    let dir = try tempDir("bad-xip")
    var bytes = fakeXipBytes
    bytes[bytes.count / 2] ^= 1
    let xip = dir.appendingPathComponent("Xcode_27.0.xip")
    try bytes.write(to: xip)
    do {
        _ = try XcodeSource.identify(path: xip.path, known: known, cwd: dir, home: dir)
        Issue.record("a one-byte-different .xip was accepted")
    } catch let e as XlessError {
        #expect(e.stage == .sdk)
        #expect(e.cause == "\(xip.path) is not a supported Xcode (supported: Xcode 26.2 (17C52), Xcode 27.0 (27A266a))")
        #expect(e.fix == "download the Universal Xcode 26.2 or 27.0 .xip from https://developer.apple.com/download/all/ (free Apple ID)")
    }
}

@Test func appIsIdentifiedByItsVersionPlist() throws {
    let dir = try tempDir("app")
    let app = try fakeApp(dir, name: "Xcode-beta.app", build: "27A266a")
    let id = try XcodeSource.identify(path: app.path, known: known, cwd: dir, home: dir)
    #expect(id.xcode.build == "27A266a")
    #expect(id.kind == .app)
}

@Test func anUnsupportedAppBuildThrows() throws {
    let dir = try tempDir("app-27.1")
    let app = try fakeApp(dir, name: "Xcode.app", build: "27A9275")
    #expect(throws: XlessError.self) { try XcodeSource.identify(path: app.path, known: known, cwd: dir, home: dir) }
    do { _ = try XcodeSource.identify(path: app.path, known: known, cwd: dir, home: dir) } catch let e as XlessError {
        #expect(e.cause.contains("Xcode 26.2 (17C52), Xcode 27.0 (27A266a)"))
    }
}

@Test func aMissingPathThrows() throws {
    let dir = try tempDir("missing")
    #expect(throws: XlessError.self) { try XcodeSource.identify(path: "nope.xip", known: known, cwd: dir, home: dir) }
}

@Test func streamingSHA256MatchesOneShot() throws {
    let dir = try tempDir("sha")
    let f = dir.appendingPathComponent("f")
    try fakeXipBytes.write(to: f)
    #expect(try XcodeSource.sha256(of: f, chunkSize: 4096) == fakeXipHash)
}
