// Differential comparison of the storyboard compiler with ibtool (research tool; not part of `swift test`).
//
// Usage: swift run IBDifferential <dir> [<xcode build>]   (the build whose ibtool made the outputs; default 27A266a)
// For every <dir>/<name>.storyboard that has an ibtool output <dir>/<name>.storyboardc (compiled with the
// universal-16 flag set by scripts/ib-corpus/differential.py), compiles the storyboard with XlessIB and prints one
// line per case: "<name> IDENTICAL", "<name> REFUSED <reason>" or "<name> MISMATCH <file>: <first differing dump
// line>"; any other error (unreadable files, an archive the reader rejects, a non-xless error) gives
// "<name> FAILED <error>" and the run goes on. Exits 1 if any case mismatches or fails. Runs anywhere; producing the
// ibtool outputs needs the Mac (scripts/ib-corpus/differential.py).
import Foundation
import XlessCore
import XlessIB

let args = CommandLine.arguments.dropFirst()
guard (1...2).contains(args.count), let dir = args.first, let profile = XcodeToolsProfile.all[args.dropFirst().first ?? "27A266a"] else {
    FileHandle.standardError.write(Data("usage: IBDifferential <dir> [<xcode build: \(XcodeToolsProfile.all.keys.sorted().joined(separator: ", "))>]\n".utf8))
    exit(2)
}
let root = URL(fileURLWithPath: dir)
let options = IBCompileOptions(targetDevices: ["iphone", "ipad"], minimumDeploymentTarget: "16.0")
let fm = FileManager.default
var failures = 0
let files: [String]
do {
    files = try fm.contentsOfDirectory(atPath: dir).sorted()
} catch {
    FileHandle.standardError.write(Data("IBDifferential: cannot list \(dir): \(error)\n".utf8))
    exit(2)
}

/// Compares one storyboard with its ibtool output; returns the output line. Throws only for failures that are not a
/// refusal by the compiler.
@MainActor func compare(_ name: String, storyboard: URL, golden: URL) throws -> String {
    let result: IBCompileResult
    do {
        result = try StoryboardCompiler.compile(url: storyboard, options: options, profile: profile)
    } catch let e as XlessError where e.stage == .ib {
        return "\(name) REFUSED \(e.cause)"
    }
    var problems: [String] = []
    let expected = try fm.contentsOfDirectory(atPath: golden.path).sorted()
    if expected != result.files.keys.sorted() { problems.append("file set \(result.files.keys.sorted()) vs \(expected)") }
    for f in expected {
        let want = try Data(contentsOf: golden.appendingPathComponent(f))
        guard let got = result.files[f], got != want else { continue }
        if f.hasSuffix(".nib") {
            let w = NIBDump.render(try NIBArchiveReader.read(want)).split(separator: "\n")
            let g = NIBDump.render(try NIBArchiveReader.read(got)).split(separator: "\n")
            let first = zip(w, g).first { $0 != $1 }.map { "ibtool \($0.0) | xless \($0.1)" } ?? "dumps equal (tables differ)"
            problems.append("\(f): \(first)")
        } else {
            problems.append("\(f) differs")
        }
    }
    return problems.isEmpty ? "\(name) IDENTICAL" : "\(name) MISMATCH \(problems.joined(separator: "; "))"
}

for file in files where file.hasSuffix(".storyboard") {
    let name = String(file.dropLast(".storyboard".count))
    let golden = root.appendingPathComponent("\(name).storyboardc")
    guard fm.fileExists(atPath: golden.path) else { continue }
    let line: String
    do {
        line = try compare(name, storyboard: root.appendingPathComponent(file), golden: golden)
    } catch {
        line = "\(name) FAILED \(String(describing: error).replacingOccurrences(of: "\n", with: " "))"
    }
    if !line.hasPrefix("\(name) IDENTICAL"), !line.hasPrefix("\(name) REFUSED") { failures += 1 }
    print(line)
}
exit(failures == 0 ? 0 : 1)
