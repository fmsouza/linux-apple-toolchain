import Testing
import Foundation
import XlessCore
@testable import XlessIB

private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-compile-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func read(_ dir: URL) throws -> [String: Data] {
    var out: [String: Data] = [:]
    for f in try FileManager.default.contentsOfDirectory(atPath: dir.path) { out[f] = try Data(contentsOf: dir.appendingPathComponent(f)) }
    return out
}

/// `real-logo-plus-label` with `replace` applied, written to `dir`.
private func variant(_ replace: [(String, String)], in dir: URL) throws -> URL {
    var xml = try String(contentsOf: CorpusCase(name: "real-logo-plus-label").storyboard, encoding: .utf8)
    for (a, b) in replace {
        #expect(xml.contains(a), "variant anchor missing: \(a)")
        xml = xml.replacingOccurrences(of: a, with: b)
    }
    let url = dir.appendingPathComponent("v.storyboard")
    try Data(xml.utf8).write(to: url)
    return url
}

@Test func runnerWritesTheGolden() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let c = CorpusCase(name: "real-logo-plus-label")
    let out = dir.appendingPathComponent("o.storyboardc")
    let r = try StoryboardCompileRunner.run(input: c.storyboard, out: out, options: .flagset(named: "universal-16", root: corpusRoot), force: false)
    #expect(r.warnings.isEmpty)
    #expect(try read(out) == c.goldenFiles(flagset: "universal-16"))
    #expect(!FileManager.default.fileExists(atPath: out.path + ".partial"))
}

@Test func runnerRefusesUnsupportedElementAndLeavesNoOutput() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let input = try variant([("<label ", #"<button id="Bt1-xT-9pQ"/><label "#)], in: dir)
    let out = dir.appendingPathComponent("o.storyboardc")
    let e = try #require(throws: XlessError.self) {
        try StoryboardCompileRunner.run(input: input, out: out, options: .flagset(named: "universal-16", root: corpusRoot), force: false)
    }
    #expect(e.stage == .ib)
    #expect(e.stage.exitCode == 18)
    #expect(e.cause.contains("<button>"))
    #expect(e.cause.contains("at line 27"))
    #expect(!FileManager.default.fileExists(atPath: out.path))
    #expect(!FileManager.default.fileExists(atPath: out.path + ".partial"))
}

@Test func runnerRefusesExistingOutputUnlessForced() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let c = CorpusCase(name: "real-logo-plus-label")
    let out = dir.appendingPathComponent("o.storyboardc")
    let opts = try IBCompileOptions.flagset(named: "universal-16", root: corpusRoot)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: out.appendingPathComponent("stale"))

    let e = try #require(throws: XlessError.self) { try StoryboardCompileRunner.run(input: c.storyboard, out: out, options: opts, force: false) }
    #expect(e.stage == .ib)
    #expect(e.cause.contains("already exists"))
    #expect(e.fix.contains("--force"))
    #expect(try read(out).keys.sorted() == ["stale"])

    _ = try StoryboardCompileRunner.run(input: c.storyboard, out: out, options: opts, force: true)
    #expect(try read(out) == c.goldenFiles(flagset: "universal-16"))
}

@Test func runnerRefusesNewerToolsVersion() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let input = try variant([(#"toolsVersion="23727""#, #"toolsVersion="25099""#)], in: dir)
    let out = dir.appendingPathComponent("o.storyboardc")
    let e = try #require(throws: XlessError.self) {
        try StoryboardCompileRunner.run(input: input, out: out, options: .flagset(named: "universal-16", root: corpusRoot), force: false)
    }
    #expect(e.stage == .ib)
    #expect(e.description.hasPrefix("[ib] storyboard was saved by a newer Xcode (toolsVersion 25099) than xless supports (25098)"))
    #expect(!FileManager.default.fileExists(atPath: out.path))

    let ok = try variant([(#"toolsVersion="23727""#, #"toolsVersion="25098""#)], in: dir)
    _ = try StoryboardCompileRunner.run(input: ok, out: out, options: .flagset(named: "universal-16", root: corpusRoot), force: false)
}

@Test func compilerItselfRefusesNewerToolsVersion() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let input = try variant([(#"toolsVersion="23727""#, #"toolsVersion="25099""#)], in: dir)
    let e = try #require(throws: XlessError.self) {
        try StoryboardCompiler.compile(url: input, options: .flagset(named: "universal-16", root: corpusRoot))
    }
    #expect(e.description.hasPrefix("[ib] storyboard was saved by a newer Xcode (toolsVersion 25099) than xless supports (25098)"))
}

@Test func cliOptionsMapToCompileOptions() throws {
    let o = try StoryboardCompileRunner.options(devices: ["iphone", "ipad", "iphone"], minimumDeploymentTarget: "16.0")
    #expect(o == IBCompileOptions(targetDevices: ["ipad", "iphone"], minimumDeploymentTarget: "16.0"))
    #expect(try StoryboardCompileRunner.options(devices: ["iphone"], minimumDeploymentTarget: "27.4").targetDevices == ["iphone"])
    for (d, t) in [(["watch"], "16.0"), ([], "16.0"), (["ipad"], "16.0"), (["iphone"], "14.0"), (["iphone"], "28.0"), (["iphone"], "sixteen")] {
        let e = try #require(throws: XlessError.self, "\(d) \(t)") { try StoryboardCompileRunner.options(devices: d, minimumDeploymentTarget: t) }
        #expect(e.stage == .ib)
        #expect(e.cause.contains("--"), "\(e)")
    }
}

@Test func missingParentDirectoryIsAnIBError() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let c = CorpusCase(name: "real-logo-plus-label")
    let out = dir.appendingPathComponent("nope/o.storyboardc")
    let e = try #require(throws: XlessError.self) {
        try StoryboardCompileRunner.run(input: c.storyboard, out: out, options: .flagset(named: "universal-16", root: corpusRoot), force: false)
    }
    #expect(e.stage == .ib)
    #expect(e.stage.exitCode == 18)
    #expect(e.cause.hasPrefix("cannot write \(out.path): "))
}

@Test func failedWriteKeepsTheOldOutputWithForce() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let c = CorpusCase(name: "real-logo-plus-label")
    let opts = try IBCompileOptions.flagset(named: "universal-16", root: corpusRoot)
    let out = dir.appendingPathComponent("o.storyboardc")
    try StoryboardCompileRunner.run(input: c.storyboard, out: out, options: opts, force: false)
    // a file name with a missing subdirectory makes the write fail after the staging directory exists
    let e = try #require(throws: XlessError.self) {
        try StoryboardCompileRunner.run(input: c.storyboard, out: out, options: opts, force: true,
                                        compile: { _, _ in IBCompileResult(files: ["Info.plist": Data("x".utf8), "missing/x.nib": Data()], warnings: []) })
    }
    #expect(e.stage == .ib)
    #expect(try read(out) == c.goldenFiles(flagset: "universal-16"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["o.storyboardc"])
}

@Test func forceOnlyReplacesStoryboardcDirectories() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let c = CorpusCase(name: "real-logo-plus-label")
    let opts = try IBCompileOptions.flagset(named: "universal-16", root: corpusRoot)
    let file = dir.appendingPathComponent("o.storyboardc")
    try Data("precious".utf8).write(to: file)
    let notStoryboardc = dir.appendingPathComponent("docs", isDirectory: true)
    try FileManager.default.createDirectory(at: notStoryboardc, withIntermediateDirectories: true)
    for out in [file, notStoryboardc] {
        let e = try #require(throws: XlessError.self) { try StoryboardCompileRunner.run(input: c.storyboard, out: out, options: opts, force: true) }
        #expect(e.cause.contains("not a .storyboardc directory"))
    }
    #expect(try Data(contentsOf: file) == Data("precious".utf8))
    #expect(FileManager.default.fileExists(atPath: notStoryboardc.path))
}

@Test func warningsGoToTheWarnSinkOnePerLine() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let c = CorpusCase(name: "real-logo-plus-label")
    var seen: [String] = []
    // The real compiler currently emits no warnings (none of the corpus cases produce any), so inject some.
    try StoryboardCompileRunner.run(input: c.storyboard, out: dir.appendingPathComponent("o.storyboardc"),
                                    options: .flagset(named: "universal-16", root: corpusRoot), force: false,
                                    compile: { _, _ in IBCompileResult(files: ["Info.plist": Data()], warnings: ["warning: one", "warning: two"]) },
                                    warn: { seen.append($0) })
    #expect(seen == ["warning: one", "warning: two"])
}

/// Final review M5: a missing `--out` parent is named, not the internal staging directory.
@Test func runnerNamesAMissingOutputParent() throws {
    let dir = try scratch()
    let out = dir.appendingPathComponent("no/such/dir/L.storyboardc")
    let e = try #require(throws: XlessError.self) {
        try StoryboardCompileRunner.run(input: CorpusCase(name: "real-logo-plus-label").storyboard, out: out,
                                        options: .flagset(named: "universal-16", root: corpusRoot), force: false)
    }
    #expect(e.stage == .ib)
    #expect(e.cause == "cannot write \(out.path): the directory \(out.deletingLastPathComponent().path) does not exist", "\(e.cause)")
    #expect(!e.cause.contains(".partial"))
}
