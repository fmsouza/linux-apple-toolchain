import Testing
import Foundation
@testable import XlessCore

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID())").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}
private func touch(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "x".write(to: url, atomically: true, encoding: .utf8)
}

@Test func xlessShareEnvWins() throws {
    let t = try tempDir()
    try touch(t.appendingPathComponent("bin/../share/xless/versions.env"))
    let root = try XlessShare.root(env: ["XLESS_SHARE": "/somewhere/else"], executable: t.appendingPathComponent("bin/xless"))
    #expect(root.path == "/somewhere/else")
}

@Test func installedLayout() throws {
    let t = try tempDir()
    try touch(t.appendingPathComponent("share/xless/versions.env"))
    let root = try XlessShare.root(env: [:], executable: t.appendingPathComponent("bin/xless"))
    #expect(root.resolvingSymlinksInPath().path == t.appendingPathComponent("share/xless").path)
}

@Test func sourceCheckout() throws {
    let t = try tempDir()
    try touch(t.appendingPathComponent("versions.env"))
    try touch(t.appendingPathComponent("docker/Dockerfile.base"))
    let root = try XlessShare.root(env: [:], executable: t.appendingPathComponent(".build/release/xless"))
    #expect(root.resolvingSymlinksInPath().path == t.path)
}

@Test func sourceCheckoutNeedsTheDockerfileToo() throws {
    let t = try tempDir()
    try touch(t.appendingPathComponent("versions.env"))
    #expect(throws: XlessError.self) { try XlessShare.root(env: [:], executable: t.appendingPathComponent(".build/release/xless")) }
}

@Test func nothingFound() throws {
    let t = try tempDir()
    do {
        _ = try XlessShare.root(env: [:], executable: t.appendingPathComponent("bin/xless"))
        Issue.record("expected a throw")
    } catch let e as XlessError {
        #expect(e.stage == .sdk)
        #expect(e.cause == "cannot find xless's share directory")
        #expect(e.fix == "reinstall xless (see README) or set XLESS_SHARE")
    }
}
