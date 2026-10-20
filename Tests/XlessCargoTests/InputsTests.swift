import Testing
import Foundation
@testable import XlessCargo
@testable import XlessCore

private var fm: FileManager { .default }

private func tempDir() throws -> URL {
    let dir = fm.temporaryDirectory.appendingPathComponent("inputs-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func git(_ dir: URL, _ args: String...) throws -> String {
    try Shell.run("git", ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "-C", dir.path] + args, stage: .prepare)
        .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A local repository standing in for the remote, with two commits.
private struct Remote {
    let dir: URL
    let first: String
    let second: String
    var url: String { "file://" + dir.path }

    init() throws {
        dir = try tempDir()
        _ = try git(dir, "init", "-q")
        try "one".write(to: dir.appendingPathComponent("font.txt"), atomically: true, encoding: .utf8)
        _ = try git(dir, "add", "font.txt")
        _ = try git(dir, "commit", "-q", "-m", "one")
        first = try git(dir, "rev-parse", "HEAD")
        try "two".write(to: dir.appendingPathComponent("font.txt"), atomically: true, encoding: .utf8)
        _ = try git(dir, "commit", "-q", "-a", "-m", "two")
        second = try git(dir, "rev-parse", "HEAD")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var clones = 0
    func run(env: [String: String]) -> ([String]) throws -> String {
        { args in
            if args.first == "clone" { self.lock.lock(); self.clones += 1; self.lock.unlock() }
            return try Shell.run("git", args, baseEnvironment: env, stage: .prepare).stdout
        }
    }
}

private func materialize(_ inputs: [CargoInput], cache: URL, sourceRoot: URL? = nil, mounted: URL? = nil,
                         env: [String: String] = ProcessInfo.processInfo.environment, git: Counter? = nil) throws -> [String: String] {
    try CargoInputs.materialize(inputs, sourceRoot: sourceRoot ?? cache, cache: cache, mounted: mounted, env: env,
                                allowFileURLs: true, git: git?.run(env: env))
}

@Suite struct InputsTests {
    @Test func clonesAtRev() throws {
        let remote = try Remote(), cache = try tempDir()
        let result = try materialize([.git(name: "fonts", url: remote.url, rev: remote.first, env: "FONTS_DIR")], cache: cache)
        let path = try #require(result["FONTS_DIR"])
        #expect(path == cache.appendingPathComponent("fonts-\(remote.first)").path)
        #expect(try git(URL(fileURLWithPath: path), "rev-parse", "HEAD") == remote.first)
        #expect(try String(contentsOfFile: path + "/font.txt", encoding: .utf8) == "one")
    }

    @Test func reusesCachedClone() throws {
        let remote = try Remote(), cache = try tempDir(), counter = Counter()
        let input = CargoInput.git(name: "fonts", url: remote.url, rev: remote.first, env: "FONTS_DIR")
        let a = try materialize([input], cache: cache, git: counter)
        let b = try materialize([input], cache: cache, git: counter)
        #expect(a == b)
        #expect(counter.clones == 1)
    }

    @Test func replacesPartial() throws {
        let remote = try Remote(), cache = try tempDir()
        let partial = cache.appendingPathComponent("fonts-\(remote.first).partial")
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        try "junk".write(to: partial.appendingPathComponent("junk"), atomically: true, encoding: .utf8)
        let result = try materialize([.git(name: "fonts", url: remote.url, rev: remote.first, env: "FONTS_DIR")], cache: cache)
        #expect(try git(URL(fileURLWithPath: try #require(result["FONTS_DIR"])), "rev-parse", "HEAD") == remote.first)
        #expect(!fm.fileExists(atPath: partial.path))
    }

    @Test func replacesWrongHead() throws {
        let remote = try Remote(), cache = try tempDir(), counter = Counter()
        let input = CargoInput.git(name: "fonts", url: remote.url, rev: remote.first, env: "FONTS_DIR")
        let path = try #require(try materialize([input], cache: cache)["FONTS_DIR"])
        _ = try git(URL(fileURLWithPath: path), "-c", "advice.detachedHead=false", "checkout", "-q", remote.second)
        let again = try #require(try materialize([input], cache: cache, git: counter)["FONTS_DIR"])
        #expect(again == path)
        #expect(counter.clones == 1)
        #expect(try git(URL(fileURLWithPath: again), "rev-parse", "HEAD") == remote.first)
    }

    @Test func unknownRevFails() throws {
        let remote = try Remote(), cache = try tempDir()
        let rev = String(repeating: "a", count: 40)
        let error = #expect(throws: XlessError.self) {
            try materialize([.git(name: "fonts", url: remote.url, rev: rev, env: "FONTS_DIR")], cache: cache)
        }
        #expect(error?.stage == .prepare)
        #expect(error?.cause.contains("fonts") == true)
        #expect(error?.cause.contains(rev) == true)
        #expect(!fm.fileExists(atPath: cache.appendingPathComponent("fonts-\(rev).partial").path))
    }

    @Test func fileURLsAreRefusedInProduction() throws {
        let remote = try Remote(), cache = try tempDir()
        let error = #expect(throws: XlessError.self) {
            try CargoInputs.materialize([.git(name: "fonts", url: remote.url, rev: remote.first, env: "FONTS_DIR")],
                                        sourceRoot: cache, cache: cache, mounted: nil, env: [:])
        }
        #expect(error?.stage == .prepare)
    }

    @Test func pathInputMissingFails() throws {
        let root = try tempDir()
        let error = #expect(throws: XlessError.self) {
            try materialize([.path(name: "fonts", path: "nope", env: "FONTS_DIR")], cache: root, sourceRoot: root)
        }
        #expect(error?.stage == .prepare)
        #expect(error?.cause.contains("fonts") == true)
    }

    @Test func pathInputResolvesRelativeAbsoluteAndHome() throws {
        let base = try tempDir()
        let root = base.appendingPathComponent("app"), sibling = base.appendingPathComponent("fonts")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        let home = base.path
        let env = ["HOME": home]
        let inputs: [CargoInput] = [
            .path(name: "rel", path: "../fonts", env: "REL_DIR"),
            .path(name: "abs", path: sibling.path, env: "ABS_DIR"),
            .path(name: "home", path: "~/fonts", env: "HOME_DIR"),
        ]
        let result = try materialize(inputs, cache: base, sourceRoot: root, env: env)
        #expect(result == ["REL_DIR": sibling.path, "ABS_DIR": sibling.path, "HOME_DIR": sibling.path])
        let mounts = CargoInputs.hostMounts(inputs, sourceRoot: root, env: env)
        #expect(mounts.map(\.name) == ["rel", "abs", "home"])
        #expect(mounts.allSatisfy { $0.path.path == sibling.path })
    }

    @Test func mountedPathInputUsesMountDirectory() throws {
        let root = try tempDir(), mounted = try tempDir()
        try fm.createDirectory(at: mounted.appendingPathComponent("fonts"), withIntermediateDirectories: true)
        let result = try materialize([.path(name: "fonts", path: "/host/elsewhere", env: "FONTS_DIR")], cache: root, sourceRoot: root, mounted: mounted)
        #expect(result == ["FONTS_DIR": mounted.appendingPathComponent("fonts").path])
    }
}
