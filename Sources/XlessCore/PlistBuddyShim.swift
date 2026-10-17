import Foundation

/// `/usr/libexec/PlistBuddy` on Linux (`xless shim plistbuddy`): the non-interactive `-c` commands React Native,
/// Expo and React Native Firebase build phases run on the built Info.plist (docs/research/react-native-ios-contract.md,
/// "Tool shims"): `Print [entry]`, `Set entry value`, `Add entry type [value]`, `Delete entry`, with entries made of
/// dictionary keys and array indexes. Messages, exit status and the XML output format follow PlistBuddy, black-box
/// (one deviation: `Print` lists dictionary keys sorted, PlistBuddy in hash order). Other commands, options, types
/// and entry syntax are refused with exit 70 and the argv, as `XcrunShim`.
public enum PlistBuddyShim {
    public struct Unsupported: Error, CustomStringConvertible, Equatable {
        public let argv: [String]
        public let reason: String
        public var description: String { "PlistBuddy shim: unsupported call (\(reason)): PlistBuddy \(argv.joined(separator: " "))" }
    }

    public struct Result: Equatable {
        public var stdout: String
        public var stderr: String
        public var exitCode: Int32
    }

    enum Command: Equatable {
        case print([Key])
        case set([Key], String)
        case add([Key], String, String?)
        case delete([Key])
    }

    enum Key: Equatable { case name(String), index(Int), append }

    static let types: Set<String> = ["string", "bool", "integer", "real", "array", "dict"]

    static func parse(_ args: [String]) throws(Unsupported) -> (commands: [Command], file: String) {
        func refuse(_ reason: String) -> Unsupported { Unsupported(argv: args, reason: reason) }
        var commands: [Command] = [], file: String?
        var i = 0
        while i < args.count {
            if args[i] == "-c" {
                guard i + 1 < args.count else { throw refuse("-c needs a command") }
                commands.append(try command(args[i + 1], refuse: refuse))
                i += 2
            } else if args[i].hasPrefix("-") {
                throw refuse("option \(args[i])")
            } else {
                guard file == nil else { throw refuse("more than one file") }
                file = args[i]; i += 1
            }
        }
        guard let file else { throw refuse("no plist file") }
        guard !commands.isEmpty else { throw refuse("interactive mode (no -c)") }
        return (commands, file)
    }

    static func command(_ text: String, refuse: (String) -> Unsupported) throws(Unsupported) -> Command {
        var rest = Substring(text).drop(while: \.isWhitespace)
        func word() -> String {
            let w = rest.prefix(while: { !$0.isWhitespace })
            rest = rest.dropFirst(w.count).drop(while: \.isWhitespace)
            return String(w)
        }
        /// The rest of the command as one value: PlistBuddy takes it verbatim, without one pair of enclosing quotes.
        func value() throws(Unsupported) -> String {
            var v = String(rest).trimmingCharacters(in: .whitespaces)
            if let q = v.first, q == "'" || q == "\"", v.count >= 2, v.last == q { v = String(v.dropFirst().dropLast()) }
            guard !v.contains("'"), !v.contains("\"") else { throw refuse("quotes inside the value of \(text)") }
            return v
        }
        func entry(_ e: String) throws(Unsupported) -> [Key] {
            guard e.hasPrefix(":"), !e.contains("\\"), !e.contains("'"), !e.contains("\"") else { throw refuse("entry \(e) in \(text)") }
            let parts = e.dropFirst().split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.dropLast().allSatisfy({ !$0.isEmpty }) else { throw refuse("entry \(e) in \(text)") }
            return parts.enumerated().map { n, p in
                if p.isEmpty { return n == parts.count - 1 ? .append : .name(p) }
                if let idx = Int(p), idx >= 0, String(idx) == p { return .index(idx) }
                return .name(p)
            }
        }
        switch word() {
        case "Print":
            let e = word()
            guard rest.isEmpty else { throw refuse("extra words in \(text)") }
            if e.isEmpty { return .print([]) }
            let keys = try entry(e)
            guard keys.last != .append else { throw refuse("entry \(e) in \(text)") }
            return .print(keys)
        case "Delete":
            let keys = try entry(word())
            guard rest.isEmpty, keys.last != .append, !keys.isEmpty else { throw refuse("Delete needs one entry: \(text)") }
            return .delete(keys)
        case "Set":
            let keys = try entry(word())
            guard keys.last != .append, !keys.isEmpty else { throw refuse("entry in \(text)") }
            return .set(keys, try value())
        case "Add":
            let keys = try entry(word())
            let type = word()
            guard !keys.isEmpty, types.contains(type) else { throw refuse("Add type \(type.isEmpty ? "(none)" : type) in \(text)") }
            if type == "array" || type == "dict" {
                guard rest.isEmpty else { throw refuse("a value for \(type) in \(text)") }
                return .add(keys, type, nil)
            }
            return .add(keys, type, try value())
        default:
            throw refuse("command \(text)")
        }
    }

    // MARK: - Running

    public static func run(_ args: [String], cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> Result {
        let parsed: (commands: [Command], file: String)
        do { parsed = try parse(args) } catch { return Result(stdout: "", stderr: "\(error)\n", exitCode: 70) }
        let url = URL(fileURLWithPath: parsed.file, relativeTo: cwd)
        var out = "", err = "", failed = false, modified = false
        var root: Any = [String: Any]()
        if let data = FileManager.default.contents(atPath: url.path) {
            guard let r = try? PropertyListSerialization.propertyList(from: data, format: nil), r is [String: Any] else {
                return Result(stdout: "", stderr: "Error Reading File: \(parsed.file)\n", exitCode: 1)
            }
            root = r
        } else {
            out += "File Doesn't Exist, Will Create: \(parsed.file)\n"
        }
        for command in parsed.commands {
            do {
                switch command {
                case .print(let keys):
                    guard let v = lookup(root, keys) else { throw Failure("Print: Entry, \"\(display(keys))\", Does Not Exist") }
                    out += try render(v, indent: 0, argv: args) + "\n"
                case .delete(let keys):
                    root = try update(root, keys, verb: "Delete") { _ in nil }
                    modified = true
                case .set(let keys, let text):
                    root = try update(root, keys, verb: "Set") { old in
                        guard let old else { throw Failure("Set: Entry, \"\(display(keys))\", Does Not Exist") }
                        guard let kind = scalarKind(old) else { throw Failure("Set: Cannot Perform Set On Containers") }
                        return try scalar(kind, text, argv: args)
                    }
                    modified = true
                case .add(let keys, let type, let text):
                    root = try update(root, keys, verb: "Add") { old in
                        guard old == nil else { throw Failure("Add: \"\(display(keys))\" Entry Already Exists") }
                        switch type {
                        case "array": return [Any]()
                        case "dict": return [String: Any]()
                        default: return try scalar(type, text ?? "", argv: args)
                        }
                    }
                    modified = true
                }
            } catch let f as Failure {
                err += f.message + "\n"; failed = true
            } catch let u as Unsupported {
                return Result(stdout: out, stderr: err + "\(u)\n", exitCode: 70)
            } catch {
                err += "\(error)\n"; failed = true
            }
        }
        if modified {
            do {
                try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0).write(to: url)
            } catch {
                return Result(stdout: out, stderr: err + "Error Writing File: \(parsed.file)\n", exitCode: 1)
            }
        }
        return Result(stdout: out, stderr: err, exitCode: failed ? 1 : 0)
    }

    struct Failure: Error { let message: String; init(_ m: String) { message = m } }

    static func display(_ keys: [Key]) -> String {
        ":" + keys.map { k in
            switch k { case .name(let n): n; case .index(let i): String(i); case .append: "" }
        }.joined(separator: ":")
    }

    static func lookup(_ v: Any, _ keys: [Key]) -> Any? {
        guard let k = keys.first else { return v }
        switch k {
        case .name(let n): return (v as? [String: Any])?[n].flatMap { lookup($0, Array(keys.dropFirst())) }
        case .index(let i):
            guard let a = v as? [Any], i < a.count else { return nil }
            return lookup(a[i], Array(keys.dropFirst()))
        case .append: return nil
        }
    }

    /// `v` with the value at `keys` replaced by `change(old)` (nil removes it). Missing intermediate containers fail
    /// with PlistBuddy's "Does Not Exist" message for the whole entry.
    static func update(_ v: Any, _ keys: [Key], verb: String, _ change: (Any?) throws -> Any?) throws -> Any {
        let missing = Failure("\(verb): Entry, \"\(display(keys))\", Does Not Exist")
        func go(_ v: Any, _ rest: ArraySlice<Key>) throws -> Any {
            let k = rest.first!
            let last = rest.count == 1
            if var d = v as? [String: Any] {
                guard case .name(let n) = k else { throw missing }
                if last {
                    let new = try change(d[n])
                    if new == nil, d[n] == nil { throw missing }
                    d[n] = new
                } else {
                    guard let child = d[n] else { throw missing }
                    d[n] = try go(child, rest.dropFirst())
                }
                return d
            }
            if var a = v as? [Any] {
                switch k {
                case .index(let i) where i < a.count:
                    if last {
                        if let new = try change(a[i]) { a[i] = new } else { a.remove(at: i) }
                    } else {
                        a[i] = try go(a[i], rest.dropFirst())
                    }
                case .index(a.count) where last && verb == "Add", .append where last && verb == "Add":
                    if let new = try change(nil) { a.append(new) }
                default:
                    throw missing
                }
                return a
            }
            throw missing
        }
        return try go(v, keys[...])
    }

    static func scalarKind(_ v: Any) -> String? {
        if v is String { return "string" }
        if isBool(v) { return "bool" }
        if let n = v as? NSNumber { return String(cString: n.objCType) == "d" || String(cString: n.objCType) == "f" ? "real" : "integer" }
        return nil
    }

    /// Plist booleans: a Swift `Bool`, or an `NSNumber` whose type is `char`/`Bool` (`CFBoolean` on Darwin).
    static func isBool(_ v: Any) -> Bool {
        if v is String || v is [Any] || v is [String: Any] { return false }
        guard let n = v as? NSNumber else { return false }
        let t = String(cString: n.objCType)
        return t == "c" || t == "B"
    }

    static func scalar(_ type: String, _ text: String, argv: [String]) throws -> Any {
        switch type {
        case "string": return text
        case "bool":
            switch text.lowercased() {
            case "yes", "true": return true
            case "no", "false": return false
            default: throw Unsupported(argv: argv, reason: "bool value \(text)")
            }
        case "integer":
            guard let i = Int(text) else { throw Unsupported(argv: argv, reason: "integer value \(text)") }
            return i
        case "real":
            guard let d = Double(text) else { throw Unsupported(argv: argv, reason: "real value \(text)") }
            return d
        default:
            throw Unsupported(argv: argv, reason: "type \(type)")
        }
    }

    static func render(_ v: Any, indent: Int, argv: [String]) throws -> String {
        let pad = String(repeating: " ", count: indent)
        if let s = v as? String { return s }
        if let d = v as? [String: Any] {
            return "Dict {\n" + (try d.keys.sorted().map { "\(pad)    \($0) = \(try render(d[$0]!, indent: indent + 4, argv: argv))\n" }.joined()) + "\(pad)}"
        }
        if let a = v as? [Any] {
            return "Array {\n" + (try a.map { "\(pad)    \(try render($0, indent: indent + 4, argv: argv))\n" }.joined()) + "\(pad)}"
        }
        if isBool(v), let n = v as? NSNumber { return n.boolValue ? "true" : "false" }
        if let n = v as? NSNumber {
            return scalarKind(n) == "real" ? String(format: "%f", n.doubleValue) : String(n.int64Value)
        }
        throw Unsupported(argv: argv, reason: "printing a \(type(of: v)) value")
    }
}
