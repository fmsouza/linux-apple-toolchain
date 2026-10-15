import Testing
import Foundation
import Crypto
@testable import XlessTauri
@testable import XlessCore

private var fm: FileManager { .default }

private func tmp() -> URL {
    fm.temporaryDirectory.appendingPathComponent("bindeps-\(UUID().uuidString)", isDirectory: true)
}

private func plist(_ url: URL, format: PropertyListSerialization.PropertyListFormat) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.a", "MinimumOSVersion": "12.0"], format: format, options: 0)
    try data.write(to: url)
}

private func sha(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

private struct Fixture {
    let zip: URL
    let sha: String
}

/// a.xcframework with an XML plist in the device slice and a binary one in the simulator slice.
private func makeZip() throws -> Fixture {
    let dir = tmp()
    let base = dir.appendingPathComponent("a.xcframework")
    try plist(base.appendingPathComponent("ios-arm64/a.framework/Info.plist"), format: .xml)
    try plist(base.appendingPathComponent("ios-arm64_x86_64-simulator/a.framework/Info.plist"), format: .binary)
    let zip = dir.appendingPathComponent("a.zip")
    try Shell.run("zip", ["-qr", zip.path, "a.xcframework"], cwd: dir, stage: .prepare)
    return Fixture(zip: zip, sha: try sha(zip))
}

private func dep(_ f: Fixture, sha: String? = nil, extract: String = "a.xcframework", to: String = "Pods/a.xcframework", min: String? = "16.0") throws -> BinaryDependency {
    var obj: [String: Any] = ["url": "https://example.com/a.zip", "sha256": sha ?? f.sha, "extract": extract, "to": to]
    if let min { obj["fixes"] = ["minimumOSVersion": min] }
    return try JSONDecoder().decode(BinaryDependency.self, from: JSONSerialization.data(withJSONObject: obj))
}

private func format(_ url: URL) throws -> (PropertyListSerialization.PropertyListFormat, [String: Any]) {
    var fmt = PropertyListSerialization.PropertyListFormat.xml
    let obj = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: &fmt)
    return (fmt, obj as! [String: Any])
}

@Suite struct BinaryDepsTests {
    @Test func installsAndPatchesPlistsPreservingFormat() throws {
        let f = try makeZip(), work = tmp(), cache = tmp()
        var calls = 0
        try BinaryDeps.install([try dep(f)], into: work, cache: cache) { _, dest in calls += 1; try fm.copyItem(at: f.zip, to: dest) }
        #expect(calls == 1)
        let a = work.appendingPathComponent("Pods/a.xcframework/ios-arm64/a.framework/Info.plist")
        let b = work.appendingPathComponent("Pods/a.xcframework/ios-arm64_x86_64-simulator/a.framework/Info.plist")
        let (fa, da) = try format(a), (fb, db) = try format(b)
        #expect(fa == .xml)
        #expect(fb == .binary)
        #expect(da["MinimumOSVersion"] as? String == "16.0")
        #expect(db["MinimumOSVersion"] as? String == "16.0")
        #expect(da["CFBundleIdentifier"] as? String == "com.example.a")
    }

    @Test func secondInstallUsesCacheAndReplacesDestination() throws {
        let f = try makeZip(), work = tmp(), cache = tmp()
        let fetch: (URL, URL) throws -> Void = { _, dest in try fm.copyItem(at: f.zip, to: dest) }
        try BinaryDeps.install([try dep(f)], into: work, cache: cache, fetch: fetch)
        try "stale".write(to: work.appendingPathComponent("Pods/a.xcframework/stale.txt"), atomically: true, encoding: .utf8)
        try BinaryDeps.install([try dep(f, sha: f.sha.uppercased())], into: work, cache: cache) { _, _ in Issue.record("fetch called on cache hit") }
        #expect(!fm.fileExists(atPath: work.appendingPathComponent("Pods/a.xcframework/stale.txt").path))
        #expect(fm.fileExists(atPath: work.appendingPathComponent("Pods/a.xcframework/ios-arm64/a.framework/Info.plist").path))
    }

    @Test func wrongShaThrowsAndLeavesNoCacheFile() throws {
        let f = try makeZip(), work = tmp(), cache = tmp()
        let wrong = String(repeating: "0", count: 64)
        do {
            try BinaryDeps.install([try dep(f, sha: wrong)], into: work, cache: cache) { _, dest in try fm.copyItem(at: f.zip, to: dest) }
            Issue.record("expected throw")
        } catch let e as XlessError {
            #expect(e.stage == .prepare)
            #expect(e.cause.contains("sha256 is \(f.sha), overlay pins \(wrong)"))
        }
        #expect((try? fm.contentsOfDirectory(atPath: cache.path)) ?? [] == [])
        #expect(!fm.fileExists(atPath: work.appendingPathComponent("Pods").path))
    }

    @Test func missingExtractPathThrows() throws {
        let f = try makeZip(), work = tmp(), cache = tmp()
        do {
            try BinaryDeps.install([try dep(f, extract: "nope.xcframework")], into: work, cache: cache) { _, dest in try fm.copyItem(at: f.zip, to: dest) }
            Issue.record("expected throw")
        } catch let e as XlessError {
            #expect(e.stage == .prepare)
            #expect(e.cause.contains("has no nope.xcframework"))
        }
    }

    @Test func refusesDestinationThroughSymlinkOutsideWork() throws {
        let f = try makeZip(), work = tmp(), cache = tmp(), outside = tmp()
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside.appendingPathComponent("a.xcframework"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: work.appendingPathComponent("Pods"), withDestinationURL: outside)
        do {
            try BinaryDeps.install([try dep(f)], into: work, cache: cache) { _, dest in try fm.copyItem(at: f.zip, to: dest) }
            Issue.record("expected throw")
        } catch let e as XlessError {
            #expect(e.stage == .prepare)
        }
        #expect(fm.fileExists(atPath: outside.appendingPathComponent("a.xcframework").path))
        #expect(!fm.fileExists(atPath: outside.appendingPathComponent("a.xcframework/ios-arm64").path))
    }
}
