import Foundation

/// What `swbuild build` writes on stdout: one message per event, each framed as `<byte count>\n<JSON object>\n` (the
/// count excludes the trailing newline; `SWBServiceConsoleBuildCommand.emitEvent`, the Swift compiler's streaming JSON
/// format). Every message has a `kind`: `taskStarted`/`taskOutput`/`taskComplete`, `taskDiagnostic`, `error`, `warning`,
/// `buildCompleted`, … (contract doc, "Swift Build on Linux — spike G2").
public enum SwiftBuildOutput {
    /// The decoded messages, in order. A frame that is not a JSON object stops the parse (the rest is not framed).
    public static func messages(_ data: Data) -> [[String: Any]] {
        var out: [[String: Any]] = []
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            var count = 0, digits = 0
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                count = count * 10 + Int(bytes[i] - 0x30); digits += 1; i += 1
            }
            guard digits > 0, i < bytes.count, bytes[i] == 0x0A, i + 1 + count <= bytes.count else { break }
            let body = Data(bytes[(i + 1)..<(i + 1 + count)])
            guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { break }
            out.append(object)
            i += 1 + count
            if i < bytes.count, bytes[i] == 0x0A { i += 1 }
        }
        return out
    }

    public struct Summary: Equatable, Sendable {
        /// `buildCompleted.result == "ok"`.
        public var succeeded: Bool
        /// `error` messages, deduplicated, in order (Swift Build also reports each failed task's diagnostics here).
        public var errors: [String]
        public var warnings: [String]
        /// `ruleInfo` of each task that completed with `failed`.
        public var failedTasks: [String]
        public var tasks: Int
        /// Lines of task output saying a command was not found (`missingCommandName` names them): build phase scripts
        /// that do not `set -e` go on after a missing macOS tool, so this is the only trace of it.
        public var commandsNotFound: [String] = []
        /// Lines of task output where an xless tool shim refused a call (`isShimRefusal`), deduplicated, in order. A
        /// phase that tests a tool (`xcrun --find actool` inside `[ … ]`) or ignores its status succeeds without it.
        public var shimRefusals: [String] = []
        /// The last `failedTaskOutputLines` lines of each failed task's output, in `failedTasks` order: the shims
        /// (strip, copypng, ditto, PlistBuddy, the linker…) give their reason on stderr, which only reaches here.
        public var failedTaskOutput: [[String]] = []

        /// The first shim refusal in a failed task's output, else in any task's: the most precise cause of a failure.
        /// (Every refusal is also in `shimRefusals`, so this is nil exactly when that is empty.)
        public var firstShimRefusal: String? {
            failedTaskOutput.lazy.flatMap { $0 }.first(where: { SwiftBuildOutput.isShimRefusal($0[...]) }) ?? shimRefusals.first
        }
    }

    /// How many lines of a failed task's output `Summary.failedTaskOutput` keeps.
    public static let failedTaskOutputLines = 20

    /// Whether a line of task output is an xless shim's refusal: `<tool> shim: unsupported call (<reason>): <argv>`
    /// (actool, ibtool, copypng, ditto, PlistBuddy, xcodebuild, strip, the linker…) or `xcrun shim: unsupported call: <argv>`.
    public static func isShimRefusal(_ line: Substring) -> Bool {
        line.contains("shim: unsupported call") && line.firstMatch(of: /(?:^|\s)[A-Za-z0-9_+.-]+ shim: unsupported call[ :(]/) != nil
    }

    /// The command a line of task output says is missing, or nil. Three shapes, all from a shell or `env` failing to
    /// start a program (Linux wording; macOS has the tools):
    /// - bash, by name: `<script>: line 4: ditto: command not found` → `ditto`;
    /// - bash, by absolute path: `<script>: line 9: /usr/libexec/PlistBuddy: No such file or directory` →
    ///   `/usr/libexec/PlistBuddy` (bash also prints this for a redirection into a missing directory, which a phase
    ///   without `set -e` survives just as silently, so it is reported the same way);
    /// - GNU `env`: `env: ‘node’: No such file or directory` (also `'node'`, and `/usr/bin/env: …`) → `node`;
    /// - a script whose `#!` interpreter is missing: `…: ./x.sh: /usr/bin/python: bad interpreter: No such file or
    ///   directory` → `/usr/bin/python`.
    public static func missingCommandName(_ line: Substring) -> String? {
        if line.hasSuffix(": command not found") {
            let head = line.dropLast(": command not found".count)
            let name = head.range(of: ": ", options: .backwards).map { head[$0.upperBound...] } ?? head
            return name.isEmpty ? nil : String(name)
        }
        guard line.hasSuffix(": No such file or directory") else { return nil }
        let head = line.dropLast(": No such file or directory".count)
        if head.hasSuffix(": bad interpreter") {
            let rest = head.dropLast(": bad interpreter".count)
            return rest.range(of: ": ", options: .backwards).map { String(rest[$0.upperBound...]) }
        }
        if let m = head.wholeMatch(of: /(?:\/usr\/bin\/)?env: [‘'](.+)[’']/) { return String(m.1) }
        if let m = head.wholeMatch(of: /.*: line [0-9]+: (\/[^:]+)/) { return String(m.1) }
        return nil
    }

    public static func summarize(_ data: Data) -> Summary {
        var started: [Int: String] = [:]
        var output: [Int: String] = [:]   // running tasks' output, dropped when they complete
        var s = Summary(succeeded: false, errors: [], warnings: [], failedTasks: [], tasks: 0)
        func scan(_ text: String) {
            for line in text.split(separator: "\n") {
                if missingCommandName(line) != nil, !s.commandsNotFound.contains(String(line)) { s.commandsNotFound.append(String(line)) }
                if isShimRefusal(line), !s.shimRefusals.contains(String(line)) { s.shimRefusals.append(String(line)) }
            }
        }
        var seenErrors = Set<String>(), seenWarnings = Set<String>()
        for m in messages(data) {
            switch m["kind"] as? String {
            case "taskStarted":
                s.tasks += 1
                if let id = m["id"] as? Int { started[id] = m["ruleInfo"] as? String ?? "" }
            case "taskOutput":
                // Kept whole per task until it completes: a line can span two messages.
                let data = m["data"] as? String ?? ""
                if let id = m["taskID"] as? Int { output[id, default: ""] += data } else { scan(data) }
            case "taskComplete":
                guard let id = m["id"] as? Int else { break }
                let text = output.removeValue(forKey: id) ?? ""
                scan(text)
                if m["result"] as? String == "failed" {
                    s.failedTasks.append(started[id] ?? "task \(id)")
                    s.failedTaskOutput.append(text.split(separator: "\n").suffix(failedTaskOutputLines).map(String.init))
                }
            case "error":
                if let text = m["message"] as? String, seenErrors.insert(text).inserted { s.errors.append(text) }
            case "warning":
                if let text = m["message"] as? String, seenWarnings.insert(text).inserted { s.warnings.append(text) }
            case "buildCompleted":
                s.succeeded = m["result"] as? String == "ok"
            default:
                break
            }
        }
        for id in output.keys.sorted() { scan(output[id]!) }   // tasks the stream never completed (a crash)
        return s
    }
}
