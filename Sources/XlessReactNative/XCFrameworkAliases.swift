import Foundation
import XlessCore

/// Lowercase aliases for the vendored frameworks CocoaPods copies out of xcframeworks (contract doc, "Case-insensitive
/// lookups"): macOS finds `#include <openssl/bio.h>` in `OpenSSL.framework` because its file system ignores case.
/// For each `install_xcframework` call of a Pods `*-xcframeworks.sh` script (CocoaPods' `[CP] Copy XCFrameworks`), a
/// symbolic link `XCFrameworkIntermediates/<destination>/<lowercase name>.framework -> <Name>.framework` is created
/// next to where the script will copy the framework (its `rsync --delete` leaves the link alone).
///
/// The script's lines are read, never run: each is split into shell words, and only the shape CocoaPods 1.15 writes
/// is accepted (double-quoted words whose only expansion is a leading `${PODS_ROOT}`, or plain words).
public enum XCFrameworkAliases {
    /// One `install_xcframework "<xcframework>" "<destination>" "<framework|library>" "<slice>"…` call.
    public struct Install: Equatable, Sendable {
        public var xcframework: String
        public var destination: String
        public var kind: String
        public var slices: [String]
    }

    /// Splits a line into shell words, expanding `${PODS_ROOT}` / `$PODS_ROOT` at the start of a double-quoted word.
    /// Refuses anything else a shell would interpret: other expansions, command substitution, escapes, operators,
    /// unterminated quotes.
    public static func words(_ line: String, podsRoot: String) throws -> [String] {
        func refuse(_ why: String) -> XlessError {
            XlessError(.build, "cannot read a CocoaPods xcframeworks script line (\(why)): \(line)",
                       fix: "this line is not the shape CocoaPods \(ReactNativeContract.cocoaPods) writes; check the pod's podspec (vendored_frameworks)")
        }
        var words: [String] = []
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if c == " " || c == "\t" { i = line.index(after: i); continue }
            var word = ""
            if c == "\"" {
                var j = line.index(after: i)
                var body = ""
                while j < line.endIndex, line[j] != "\"" { body.append(line[j]); j = line.index(after: j) }
                guard j < line.endIndex else { throw refuse("unterminated quote") }
                for prefix in ["${PODS_ROOT}", "$PODS_ROOT"] where body.hasPrefix(prefix) {
                    body = podsRoot + body.dropFirst(prefix.count)
                    break
                }
                if body.contains("$") || body.contains("`") || body.contains("\\") { throw refuse("an expansion other than a leading ${PODS_ROOT}") }
                word = body
                i = line.index(after: j)
            } else {
                var j = i
                while j < line.endIndex, line[j] != " ", line[j] != "\t" { word.append(line[j]); j = line.index(after: j) }
                if word.wholeMatch(of: /[A-Za-z0-9_.\/+@=,:-]+/) == nil { throw refuse("an unquoted word with shell syntax: \(word)") }
                i = j
            }
            if i < line.endIndex, line[i] != " ", line[i] != "\t" { throw refuse("characters right after a quoted word") }
            words.append(word)
        }
        return words
    }

    /// The `install_xcframework` calls of a script (its function definition, `install_xcframework() {`, is not one).
    public static func installs(script: String, podsRoot: String) throws -> [Install] {
        try script.split(whereSeparator: \.isNewline).compactMap { raw -> Install? in
            let line = raw.drop { $0 == " " || $0 == "\t" }
            guard line.hasPrefix("install_xcframework ") || line.hasPrefix("install_xcframework\t") else { return nil }
            let w = try words(String(line), podsRoot: podsRoot)
            guard w.count >= 5, w[0] == "install_xcframework", w[1].hasSuffix(".xcframework"), ["framework", "library"].contains(w[3]),
                  !w[2].isEmpty, !w[2].hasPrefix("/"), !w[2].split(separator: "/").contains("..") else {
                throw XlessError(.build, "unexpected install_xcframework call: \(line)",
                                 fix: "expected install_xcframework \"<path>.xcframework\" \"<destination>\" \"framework|library\" \"<slice>\"…")
            }
            return Install(xcframework: w[1], destination: w[2], kind: w[3], slices: Array(w[4...]))
        }
    }

    /// The aliases for `installs`: (directory relative to XCFrameworkIntermediates, link name, link target).
    public static func aliases(_ installs: [Install]) -> [(dir: String, link: String, target: String)] {
        var out: [(String, String, String)] = []
        for i in installs where i.kind == "framework" {
            let name = String((i.xcframework as NSString).lastPathComponent.dropLast(".xcframework".count))
            let lower = name.lowercased()
            guard lower != name else { continue }
            out.append((i.destination, "\(lower).framework", "\(name).framework"))
        }
        return out
    }

    /// Creates the aliases of every `Pods/Target Support Files/*/*-xcframeworks.sh` under `pods` in `intermediates`
    /// (`<derived data>/Products/<configuration>-iphoneos/XCFrameworkIntermediates`); returns how many.
    @discardableResult
    public static func create(pods: URL, intermediates: URL) throws -> Int {
        let fm = FileManager.default
        let support = pods.appendingPathComponent("Target Support Files")
        var count = 0
        for dir in ((try? fm.contentsOfDirectory(atPath: support.path)) ?? []).sorted() {
            let d = support.appendingPathComponent(dir)
            for file in ((try? fm.contentsOfDirectory(atPath: d.path)) ?? []).sorted() where file.hasSuffix("-xcframeworks.sh") {
                let url = d.appendingPathComponent(file)
                guard let script = try? String(contentsOf: url, encoding: .utf8) else {
                    throw XlessError(.build, "cannot read \(url.path)", fix: "run xless prepare again (pod install writes it)")
                }
                for alias in aliases(try installs(script: script, podsRoot: pods.path)) {
                    let at = intermediates.appendingPathComponent(alias.dir)
                    try fm.createDirectory(at: at, withIntermediateDirectories: true)
                    let link = at.appendingPathComponent(alias.link)
                    if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                        if existing == alias.target { count += 1; continue }
                        try fm.removeItem(at: link)   // the link itself, never what it points to
                    } else if (try? fm.attributesOfItem(atPath: link.path)) != nil {
                        continue   // a real file or directory of that name: not ours to replace
                    }
                    try fm.createSymbolicLink(atPath: link.path, withDestinationPath: alias.target)
                    count += 1
                }
            }
        }
        return count
    }
}
