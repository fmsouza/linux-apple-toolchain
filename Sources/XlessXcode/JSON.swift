import Foundation
import XlessCore

/// A JSON value with deterministic output: object keys are written sorted, strings with the minimal escapes, the same
/// bytes on macOS and Linux (PIF signatures hash this text).
public indirect enum JSON: Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([JSON])
    case object([String: JSON])

    public func serialized(pretty: Bool = false) -> String {
        var out = ""
        write(to: &out, pretty: pretty, indent: 0)
        return out
    }

    private func write(to out: inout String, pretty: Bool, indent: Int) {
        switch self {
        case .string(let s): Self.quote(s, into: &out)
        case .int(let i): out += String(i)
        case .bool(let b): out += b ? "true" : "false"
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                if pretty { out += "\n" + String(repeating: "  ", count: indent + 1) }
                item.write(to: &out, pretty: pretty, indent: indent + 1)
            }
            if pretty { out += "\n" + String(repeating: "  ", count: indent) }
            out += "]"
        case .object(let dict):
            if dict.isEmpty { out += "{}"; return }
            out += "{"
            for (i, key) in dict.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                if pretty { out += "\n" + String(repeating: "  ", count: indent + 1) }
                Self.quote(key, into: &out)
                out += pretty ? ": " : ":"
                dict[key]!.write(to: &out, pretty: pretty, indent: indent + 1)
            }
            if pretty { out += "\n" + String(repeating: "  ", count: indent) }
            out += "}"
        }
    }

    private static func quote(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20:
                out += "\\u" + String(repeating: "0", count: 4 - String(u.value, radix: 16).count) + String(u.value, radix: 16)
            default: out.unicodeScalars.append(u)
            }
        }
        out += "\""
    }

    /// Converts a `JSONSerialization` result (used for PIF fragments xless reads, e.g. a package's `dump-pif`).
    /// Booleans stay booleans on both platforms (`FoundationScalar`). `null` and non-integral numbers have no PIF
    /// meaning and are refused.
    public init(foundation value: Any) throws {
        switch value {
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(try a.map { try JSON(foundation: $0) })
        case let d as [String: Any]: self = .object(try d.mapValues { try JSON(foundation: $0) })
        case is NSNull:
            throw XlessError(.prepare, "JSON null is not a PIF value (it would have to be guessed as an empty string or a missing key)",
                             fix: "regenerate the PIF (swift package dump-pif); report the file if it still has one")
        default:
            switch FoundationScalar(value) {
            case .bool(let b)?: self = .bool(b)
            case .int(let i)?: self = .int(Int(i))
            case .uint(let u)? where u <= UInt64(Int.max): self = .int(Int(u))
            case .real(let d)? where d == d.rounded() && abs(d) < 9.0e15: self = .int(Int(d))
            case nil:
                throw XlessError(.prepare, "unsupported JSON value of type \(type(of: value))", fix: "regenerate the PIF (swift package dump-pif)")
            default:
                throw XlessError(.prepare, "JSON number \(value) is not an integer; PIF fragments hold only strings, integers, booleans, arrays and objects",
                                 fix: "regenerate the PIF (swift package dump-pif); report the file if it still has one")
            }
        }
    }

    public subscript(key: String) -> JSON? {
        if case .object(let d) = self { d[key] } else { nil }
    }

    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var arrayValue: [JSON]? { if case .array(let a) = self { a } else { nil } }
}

/// 64-bit FNV-1a, for stable GUIDs and signatures (not security relevant).
enum FNV {
    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
