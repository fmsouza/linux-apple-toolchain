import Testing
import Foundation
@testable import XlessXcode

let fixturesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The PIF `PIFWriter` writes for our sample projects, compared with what `xcodebuild -dumpPIF` (Xcode 27.0, 27A266a)
/// writes for the same projects, both normalised by `PIFNormaliser`. The goldens in Fixtures/golden are the normalised
/// Xcode dumps; regenerate them on a Mac with `XLESS_XCODE_PIF_DUMPS=<dir> swift test --filter regenerateGoldens`,
/// where <dir> holds `<case>.pif` dumps and `roots.json` ({"<case>": "<directory the dump was taken in>"}).
struct GoldenCase: CustomTestStringConvertible, Sendable {
    let name: String
    /// The workspace or project to load, and the directory paths are relative to.
    let container: URL
    let root: URL
    let packages: [String]

    var testDescription: String { name }

    static let all = [
        GoldenCase(name: "HelloPIF", container: repoRoot.appendingPathComponent("samples/HelloPIF/HelloPIF.xcodeproj"),
                   root: repoRoot.appendingPathComponent("samples/HelloPIF"), packages: []),
        GoldenCase(name: "PodsStyle", container: fixturesDir.appendingPathComponent("PodsStyle/PodsStyle.xcworkspace"),
                   root: fixturesDir.appendingPathComponent("PodsStyle"), packages: []),
        GoldenCase(name: "ExtPkg", container: fixturesDir.appendingPathComponent("ExtPkg/ExtPkg.xcworkspace"),
                   root: fixturesDir.appendingPathComponent("ExtPkg"), packages: ["greetingkit"]),
        GoldenCase(name: "HelloRN", container: fixturesDir.appendingPathComponent("HelloRN/HelloRN.xcodeproj"),
                   root: fixturesDir.appendingPathComponent("HelloRN"), packages: []),
    ]

    var golden: URL { fixturesDir.appendingPathComponent("golden/\(name).pif.json") }

    func generated() throws -> JSON {
        let ws = try XcodeWorkspace.load(container)
        let packages = try self.packages.map {
            try ResolvedPackage(identity: $0, dumpPIF: Data(contentsOf: fixturesDir.appendingPathComponent("ExtPkg/GreetingKit.dump-pif.json")))
        }
        return PIFNormaliser.normalise(try PIFWriter.objects(ws, packages: packages), root: root.standardizedFileURL.path)
    }
}

@Test(arguments: GoldenCase.all)
func pifMatchesXcodeDump(_ c: GoldenCase) throws {
    let expected = try JSON(foundation: JSONSerialization.jsonObject(with: Data(contentsOf: c.golden)))
    let actual = try c.generated()
    if actual != expected {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-pif-golden")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(actual.serialized(pretty: true).utf8).write(to: dir.appendingPathComponent("\(c.name).actual.json"))
        try? Data(expected.serialized(pretty: true).utf8).write(to: dir.appendingPathComponent("\(c.name).expected.json"))
        Issue.record("PIF for \(c.name) differs from the normalised Xcode dump; diff \(dir.path)/\(c.name).{expected,actual}.json")
    }
}

@Test func regenerateGoldens() throws {
    guard let dumps = ProcessInfo.processInfo.environment["XLESS_XCODE_PIF_DUMPS"] else { return }
    let dir = URL(fileURLWithPath: dumps)
    let roots = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("roots.json"))) as! [String: String]
    for c in GoldenCase.all {
        let dump = try PIFNormaliser.load(dir.appendingPathComponent("\(c.name).pif"))
        let normalised = PIFNormaliser.normalise(dump, root: roots[c.name]!)
        try FileManager.default.createDirectory(at: c.golden.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((normalised.serialized(pretty: true) + "\n").utf8).write(to: c.golden)
    }
}
