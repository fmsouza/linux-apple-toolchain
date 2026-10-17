import Foundation
import XlessCore

/// Progress on stderr (stdout carries each stage's result).
func log(_ message: String) {
    FileHandle.standardError.write(Data("xless: \(message)\n".utf8))
}

/// The first non-nil `body(directory)` from `start` up to `root` (both included), as Node, Bundler and monorepo
/// tools look for their files; nil when `start` is not inside `root`.
func walkUp<T>(from start: URL, to root: URL, _ body: (URL) -> T?) -> T? {
    var d = start.standardizedFileURL
    let stop = root.standardizedFileURL.path
    while d.path == stop || d.path.hasPrefix(stop + "/") {
        if let found = body(d) { return found }
        if d.path == stop { return nil }
        d = d.deletingLastPathComponent()
    }
    return nil
}

/// `body` with every `XlessError` reported for `stage`: lower layers (XlessXcode reads the workspace for prepare and
/// build alike) name their own stage, but the failure belongs to the stage that ran them (exit code, `[stage]`).
func restage<T>(_ stage: Stage, _ body: () throws -> T) throws -> T {
    do { return try body() } catch let e as XlessError where e.stage != stage {
        throw XlessError(stage, e.cause, fix: e.fix)
    }
}
