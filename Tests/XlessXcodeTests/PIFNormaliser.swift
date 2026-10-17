import Foundation
@testable import XlessXcode

/// Puts a PIF (Xcode's `-dumpPIF` or `PIFWriter`'s) into a canonical form, so the two can be compared:
/// - objects ordered workspace, then each project followed by its targets; signatures dropped (the `projects` and
///   `targets` lists become the referenced objects' GUIDs);
/// - every GUID renamed `G<n>` in order of definition (a depth-first walk with sorted keys), so equal structure gives
///   equal names whatever the GUID scheme;
/// - the fixture root replaced by `$ROOT` in strings;
/// - Swift package projects (`PACKAGE:` GUIDs; Xcode and SwiftPM generate them differently) and the keys in
///   `ignoredKeys` dropped.
enum PIFNormaliser {
    /// `predominantSourceCodeLanguage`: Xcode's heuristic is not reproduced exactly; only Core ML / Intents code
    /// generation reads it (see the task report).
    static let ignoredKeys: Set<String> = ["predominantSourceCodeLanguage"]

    static func normalise(_ objects: [JSON], root: String) -> JSON {
        var bySignature: [String: JSON] = [:]
        for o in objects { if let s = o["signature"]?.stringValue { bySignature[s] = o } }
        func contents(_ sig: String) -> JSON? { bySignature[sig]?["contents"] }
        func isPackage(_ c: JSON?) -> Bool { c?["guid"]?.stringValue?.hasPrefix("PACKAGE") ?? false }

        guard let ws = objects.first(where: { $0["type"]?.stringValue == "workspace" })?["contents"] else { return .array([]) }
        var ordered: [JSON] = []
        var projectGUIDs: [JSON] = []
        for psig in ws["projects"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            guard let p = contents(psig), !isPackage(p) else { continue }
            projectGUIDs.append(p["guid"]!)
            var targetGUIDs: [JSON] = []
            var targets: [JSON] = []
            for tsig in p["targets"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                guard let t = contents(tsig) else { continue }
                targetGUIDs.append(t["guid"]!)
                targets.append(.object(["type": .string("target"), "contents": t]))
            }
            ordered.append(.object(["type": .string("project"), "contents": replacing(p, "targets", .array(targetGUIDs))]))
            ordered += targets
        }
        let workspace = JSON.object(["type": .string("workspace"), "contents": replacing(ws, "projects", .array(projectGUIDs))])
        var all = JSON.array([workspace] + ordered)

        // Definitions: the "guid" of every dictionary except references ({guid, name} dependency entries).
        var names: [String: String] = [:]
        func define(_ v: JSON, parentKey: String?) {
            switch v {
            case .object(let d):
                if parentKey != "dependencies", let g = d["guid"]?.stringValue, names[g] == nil { names[g] = "G\(names.count)" }
                for k in d.keys.sorted() { define(d[k]!, parentKey: k) }
            case .array(let a): for x in a { define(x, parentKey: parentKey) }
            default: break
            }
        }
        define(all, parentKey: nil)
        let roots = [root, root.hasPrefix("/private/") ? String(root.dropFirst(8)) : "/private" + root]
        func rewrite(_ v: JSON) -> JSON {
            switch v {
            case .string(let s):
                if let n = names[s] { return .string(n) }
                var s = s
                for r in roots { s = s.replacingOccurrences(of: r, with: "$ROOT") }
                return .string(s)
            case .array(let a): return .array(a.map(rewrite))
            case .object(let d):
                var out: [String: JSON] = [:]
                for (k, x) in d where !ignoredKeys.contains(k) {
                    // Xcode writes an uninitialised number for `fileEncoding = undefined` (the `xcode` npm package).
                    if k == "fileTextEncoding", let s = x.stringValue, s.allSatisfy(\.isNumber) { continue }
                    out[k] = rewrite(x)
                }
                return .object(out)
            default: return v
            }
        }
        all = rewrite(all)
        return all
    }

    static func replacing(_ o: JSON, _ key: String, _ value: JSON) -> JSON {
        guard case .object(var d) = o else { return o }
        d[key] = value
        return .object(d)
    }

    static func load(_ url: URL) throws -> [JSON] {
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try JSON(foundation: parsed).arrayValue ?? []
    }
}
