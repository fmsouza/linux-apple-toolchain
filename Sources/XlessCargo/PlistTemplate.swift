import Foundation
import XlessCore

/// `@NAME@` placeholders in an Info.plist template. A name is an upper-case letter followed by upper-case letters,
/// digits and `_`; anything else with an `@` in it (`user@example.com`, `@lower@`) is plain text.
public enum PlistTemplate {
    /// Nested containers deeper than this are refused (a plist is read from the app's repository).
    static let maxDepth = 64

    /// `plist` with every `@NAME@` in a string value (at any depth) replaced by `vars[NAME]`. Replacements are not
    /// scanned again. Names without a value fail with one `.build` error listing all of them, sorted.
    public static func expand(_ plist: [String: Any], vars: [String: String]) throws -> [String: Any] {
        var missing = Set<String>()
        let out = try expandDictionary(plist, vars: vars, missing: &missing, depth: 0)
        if !missing.isEmpty {
            throw XlessError(.build, "Info.plist placeholders without a value: \(missing.sorted().joined(separator: ", "))",
                             fix: "define them under plistVars: in the overlay (built-in: \(vars.keys.sorted().joined(separator: ", ")))")
        }
        return out
    }

    /// Replaces the placeholders of one string; names without a value are added to `missing` and left in place.
    static func expand(_ text: String, vars: [String: String], missing: inout Set<String>) -> String {
        let bytes = Array(text.utf8)
        guard bytes.contains(UInt8(ascii: "@")) else { return text }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "@"), let (name, end) = token(in: bytes, at: i) {
                if let value = vars[name] { out.append(contentsOf: value.utf8) } else {
                    missing.insert(name)
                    out.append(contentsOf: bytes[i..<end])
                }
                i = end
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The placeholder starting at `start` (an `@`): its name and the index after the closing `@`.
    private static func token(in bytes: [UInt8], at start: Int) -> (String, Int)? {
        var j = start + 1
        guard j < bytes.count, (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(bytes[j]) else { return nil }
        while j < bytes.count {
            let b = bytes[j]
            let isName = (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(b) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) || b == UInt8(ascii: "_")
            if !isName { break }
            j += 1
        }
        guard j < bytes.count, bytes[j] == UInt8(ascii: "@") else { return nil }
        return (String(decoding: bytes[(start + 1)..<j], as: UTF8.self), j + 1)
    }

    private static func tooDeep() -> XlessError {
        XlessError(.build, "the Info.plist template nests dictionaries or arrays more than \(maxDepth) levels deep", fix: "flatten the template")
    }

    private static func expandDictionary(_ dict: [String: Any], vars: [String: String], missing: inout Set<String>, depth: Int) throws -> [String: Any] {
        guard depth <= maxDepth else { throw tooDeep() }
        var out: [String: Any] = [:]
        for (key, value) in dict { out[key] = try expandValue(value, vars: vars, missing: &missing, depth: depth + 1) }
        return out
    }

    private static func expandValue(_ value: Any, vars: [String: String], missing: inout Set<String>, depth: Int) throws -> Any {
        switch value {
        case let s as String: return expand(s, vars: vars, missing: &missing)
        case let d as [String: Any]: return try expandDictionary(d, vars: vars, missing: &missing, depth: depth)
        case let a as [Any]:
            guard depth <= maxDepth else { throw tooDeep() }
            return try a.map { try expandValue($0, vars: vars, missing: &missing, depth: depth + 1) }
        default: return value
        }
    }
}
