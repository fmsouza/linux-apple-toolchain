import Foundation
import XlessCore

/// A value of an OpenStep ("ASCII") property list, the format of `project.pbxproj`. pbxproj files hold only strings,
/// arrays and dictionaries (numbers and booleans are unquoted strings), so those are the only cases.
public indirect enum PlistValue: Equatable, Sendable {
    case string(String)
    case array([PlistValue])
    case dict([String: PlistValue])

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var array: [PlistValue]? { if case .array(let a) = self { a } else { nil } }
    public var dict: [String: PlistValue]? { if case .dict(let d) = self { d } else { nil } }
}

/// Parser for the OpenStep plist syntax Xcode, CocoaPods (`xcodeproj` gem) and the `xcode` npm package write:
/// `{ key = value; }`, `( a, b, )`, quoted and unquoted strings, `//` and `/* */` comments. `<…>` data is refused
/// (pbxproj files do not use it). Written here rather than through `PropertyListSerialization` so errors carry a line
/// number and the parse is identical on macOS and Linux.
enum OpenStepPlist {
    static func parse(_ data: Data, file: String) throws -> PlistValue {
        var p = Parser(bytes: Array(data), file: file)
        p.skipTrivia()
        let value = try p.value()
        p.skipTrivia()
        guard p.atEnd else { throw p.error("unexpected text after the root object") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        let file: String
        var pos = 0
        var line = 1

        init(bytes: [UInt8], file: String) {
            self.bytes = bytes
            self.file = file
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { pos = 3 }  // UTF-8 BOM
        }

        var atEnd: Bool { pos >= bytes.count }

        func error(_ what: String) -> XlessError {
            XlessError(.prepare, "cannot parse \(file) at line \(line): \(what)",
                       fix: "the file must be a valid Xcode project; re-save it in Xcode or regenerate it (expo prebuild, pod install)")
        }

        mutating func skipTrivia() {
            while pos < bytes.count {
                let c = bytes[pos]
                if c == UInt8(ascii: "\n") { line += 1; pos += 1 }
                else if c == 0x20 || c == 0x09 || c == 0x0D { pos += 1 }
                else if c == UInt8(ascii: "/"), pos + 1 < bytes.count, bytes[pos + 1] == UInt8(ascii: "/") {
                    while pos < bytes.count, bytes[pos] != UInt8(ascii: "\n") { pos += 1 }
                } else if c == UInt8(ascii: "/"), pos + 1 < bytes.count, bytes[pos + 1] == UInt8(ascii: "*") {
                    pos += 2
                    while pos < bytes.count, !(bytes[pos] == UInt8(ascii: "*") && pos + 1 < bytes.count && bytes[pos + 1] == UInt8(ascii: "/")) {
                        if bytes[pos] == UInt8(ascii: "\n") { line += 1 }
                        pos += 1
                    }
                    pos = min(pos + 2, bytes.count)
                } else { return }
            }
        }

        mutating func expect(_ ch: Character) throws {
            skipTrivia()
            guard pos < bytes.count, bytes[pos] == ch.asciiValue! else {
                throw error("expected '\(ch)'")
            }
            pos += 1
        }

        mutating func value() throws -> PlistValue {
            skipTrivia()
            guard pos < bytes.count else { throw error("unexpected end of file") }
            switch bytes[pos] {
            case UInt8(ascii: "{"):
                pos += 1
                var dict: [String: PlistValue] = [:]
                while true {
                    skipTrivia()
                    guard pos < bytes.count else { throw error("unterminated dictionary") }
                    if bytes[pos] == UInt8(ascii: "}") { pos += 1; return .dict(dict) }
                    let key = try string()
                    try expect("=")
                    let v = try value()
                    try expect(";")
                    dict[key] = v
                }
            case UInt8(ascii: "("):
                pos += 1
                var items: [PlistValue] = []
                while true {
                    skipTrivia()
                    guard pos < bytes.count else { throw error("unterminated array") }
                    if bytes[pos] == UInt8(ascii: ")") { pos += 1; return .array(items) }
                    items.append(try value())
                    skipTrivia()
                    guard pos < bytes.count else { throw error("unterminated array") }
                    if bytes[pos] == UInt8(ascii: ",") { pos += 1 }
                    else if bytes[pos] != UInt8(ascii: ")") { throw error("expected ',' or ')' in array") }
                }
            case UInt8(ascii: "<"):
                throw error("<data> values are not supported in project files")
            default:
                return .string(try string())
            }
        }

        mutating func string() throws -> String {
            skipTrivia()
            guard pos < bytes.count else { throw error("unexpected end of file") }
            if bytes[pos] == UInt8(ascii: "\"") { return try quoted() }
            let start = pos
            while pos < bytes.count, Self.isUnquoted(bytes[pos]) { pos += 1 }
            guard pos > start else { throw error("unexpected character '\(Character(UnicodeScalar(bytes[pos])))'") }
            return String(decoding: bytes[start..<pos], as: UTF8.self)
        }

        static func isUnquoted(_ c: UInt8) -> Bool {
            switch c {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                true
            case UInt8(ascii: "_"), UInt8(ascii: "$"), UInt8(ascii: "+"), UInt8(ascii: "/"), UInt8(ascii: ":"),
                 UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "~"), UInt8(ascii: "@"), UInt8(ascii: "["),
                 UInt8(ascii: "]"), UInt8(ascii: "*"), UInt8(ascii: "!"), UInt8(ascii: "?"), UInt8(ascii: "%"),
                 UInt8(ascii: "&"), UInt8(ascii: "#"), UInt8(ascii: "^"), UInt8(ascii: "|"), UInt8(ascii: "'"):
                true
            default:
                c >= 0x80
            }
        }

        mutating func quoted() throws -> String {
            pos += 1  // opening quote
            var out: [UInt8] = []
            while true {
                guard pos < bytes.count else { throw error("unterminated quoted string") }
                let c = bytes[pos]
                pos += 1
                if c == UInt8(ascii: "\"") { break }
                if c == UInt8(ascii: "\n") { line += 1 }
                guard c == UInt8(ascii: "\\") else { out.append(c); continue }
                guard pos < bytes.count else { throw error("unterminated escape") }
                let e = bytes[pos]
                pos += 1
                switch e {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "a"): out.append(0x07)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "v"): out.append(0x0B)
                case UInt8(ascii: "U"):
                    var scalar: UInt32 = 0
                    for _ in 0..<4 {
                        guard pos < bytes.count, let d = Self.hex(bytes[pos]) else { throw error("bad \\U escape") }
                        scalar = scalar << 4 | d
                        pos += 1
                    }
                    guard let u = UnicodeScalar(scalar) else { throw error("bad \\U escape") }
                    out.append(contentsOf: Array(String(Character(u)).utf8))
                case UInt8(ascii: "0")...UInt8(ascii: "7"):
                    var v = UInt32(e - UInt8(ascii: "0"))
                    for _ in 0..<2 where pos < bytes.count && (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(bytes[pos]) {
                        v = v << 3 | UInt32(bytes[pos] - UInt8(ascii: "0"))
                        pos += 1
                    }
                    out.append(UInt8(truncatingIfNeeded: v))
                case UInt8(ascii: "\n"): line += 1; out.append(e)
                default: out.append(e)  // \" \\ \' and anything else: the character itself
                }
            }
            return String(decoding: out, as: UTF8.self)
        }

        static func hex(_ c: UInt8) -> UInt32? {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt32(c - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): UInt32(c - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): UInt32(c - UInt8(ascii: "A") + 10)
            default: nil
            }
        }
    }
}
