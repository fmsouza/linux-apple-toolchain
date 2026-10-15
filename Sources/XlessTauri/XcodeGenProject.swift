import Foundation
import Yams
import XlessCore

public struct XcodeGenTarget: @unchecked Sendable {
    public struct Source: Equatable, Sendable {
        public var path: String
        public var buildPhase: String?
        public var type: String?
    }
    public enum Dependency: Equatable, Sendable {
        case framework(path: String, embed: Bool, codeSign: Bool)
        case sdk(String)
    }
    public struct Script: Equatable, Sendable {
        public var name: String
        public var script: String
    }
    public var name: String
    public var sources: [Source]
    public var infoPath: String
    public var infoProperties: [String: Any]
    public var entitlementsPath: String?
    /// `settings.base` values, with array values joined by spaces; `settings.groups` entries merge in first.
    public var settings: [String: String]
    public var dependencies: [Dependency]
    public var preBuildScripts: [Script]
    public var postCompileScripts: [Script]
    /// The target's own `deploymentTarget`, else `options.deploymentTarget.iOS`.
    public var deploymentTarget: String?
}

/// Reads the subset of an XcodeGen `project.yml` that `tauri ios init` generates (spec §2.1).
public enum XcodeGenProject {
    private indirect enum Allowed: Sendable {
        case any                       // accepted, contents not inspected
        case scalar
        case map([String: Allowed])
        case list(Allowed)
    }

    private static let scriptKeys: Allowed = .list(.map([
        "name": .scalar, "script": .scalar, "basedOnDependencyAnalysis": .scalar, "inputFiles": .any, "outputFiles": .any,
        "inputFileLists": .any, "outputFileLists": .any, "shell": .scalar, "showEnvVars": .scalar,
    ]))
    private static let target: Allowed = .map([
        "type": .scalar, "platform": .scalar, "deploymentTarget": .scalar,
        "sources": .list(.map(["path": .scalar, "buildPhase": .any, "type": .scalar, "excludes": .any, "name": .scalar, "createIntermediateGroups": .scalar])),
        "info": .map(["path": .scalar, "properties": .any]),
        "entitlements": .map(["path": .scalar]),
        "settings": .map(["base": .any, "groups": .any]),
        "dependencies": .list(.map(["framework": .scalar, "sdk": .scalar, "embed": .scalar, "codeSign": .scalar])),
        "preBuildScripts": scriptKeys, "postCompileScripts": scriptKeys,
        "scheme": .any,
    ])
    private static let root: Allowed = .map([
        "name": .scalar, "options": .any, "fileGroups": .any, "configs": .any, "settingGroups": .any, "targetTemplates": .any,
        "targets": .map([:]),   // per-target keys come from `target`
    ])

    public static func parse(yaml: String, file: String) throws -> (projectName: String, target: XcodeGenTarget) {
        let fix = "xless supports the subset `tauri ios init` generates; see docs/tauri.md"
        func fail(_ cause: String) -> XlessError { XlessError(.prepare, cause, fix: fix) }
        let rootNode: Node
        do {
            guard let n = try Yams.compose(yaml: yaml) else { throw fail("\(file): project.yml is empty") }
            rootNode = n
        } catch let e as XlessError { throw e } catch {
            throw fail("\(file): project.yml is not valid YAML: \(error)")
        }
        guard case .mapping(let top) = rootNode else { throw fail("\(file):1: project.yml is not a mapping") }

        // Unsupported-key check against the allow-list.
        func check(_ node: Node, _ allowed: Allowed, _ path: String) throws {
            switch (node, allowed) {
            case (.mapping(let m), .map(let keys)):
                for (k, v) in m {
                    let key = k.string ?? ""
                    let sub = path.isEmpty ? key : "\(path).\(key)"
                    if path == "targets" {
                        guard case .mapping = v else { throw fail("\(file):\((v.mark?.line ?? 1)): target '\(key)' is not a mapping") }
                        try check(v, target, sub)
                    } else if let a = keys[key] {
                        try check(v, a, sub)
                    } else {
                        throw fail("\(file):\(k.mark?.line ?? 1): unsupported project.yml key '\(sub)'")
                    }
                }
            case (.sequence(let s), .list(let item)):
                for (i, n) in s.enumerated() {
                    // A bare string is allowed for `sources` entries (XcodeGen shorthand).
                    if case .scalar = n, path.hasSuffix(".sources") { continue }
                    try check(n, item, "\(path)[\(i)]")
                }
            default: break
            }
        }
        try check(rootNode, root, "")

        let projectName = top["name"]?.string ?? ""
        guard case .mapping(let targets)? = top["targets"], !targets.isEmpty else {
            throw fail("\(file):\(top["targets"]?.mark?.line ?? 1): project.yml has no targets")
        }
        let apps = targets.filter { t in
            guard case .mapping(let m) = t.value else { return false }
            return m["type"]?.string == "application" && m["platform"]?.string == "iOS"
        }
        guard targets.count == 1, apps.count == 1 else {
            throw fail("\(file):\(top["targets"]?.mark?.line ?? 1): project.yml must define exactly one application target with platform: iOS (found \(targets.count) target(s), \(apps.count) iOS application(s))")
        }
        let (nameNode, targetNode) = apps[0]
        guard case .mapping(let tm) = targetNode else { throw fail("\(file): target is not a mapping") }
        let name = nameNode.string ?? ""
        let line = nameNode.mark?.line ?? 1

        func settingString(_ n: Node) -> String? {
            switch n {
            case .scalar(let s): s.string
            case .sequence(let seq): seq.compactMap { $0.string }.joined(separator: " ")
            default: nil
            }
        }
        func baseSettings(_ n: Node?) -> [String: String] {
            guard case .mapping(let m)? = n else { return [:] }
            var out: [String: String] = [:]
            for (k, v) in m { if let key = k.string, let val = settingString(v) { out[key] = val } }
            return out
        }

        var settings: [String: String] = [:]
        if case .mapping(let sm)? = tm["settings"] {
            if case .mapping(let groups)? = top["settingGroups"], case .sequence(let used)? = sm["groups"] {
                for g in used {
                    if let gn = g.string, case .mapping(let gm)? = groups[gn] { settings.merge(baseSettings(gm["base"])) { _, new in new } }
                }
            }
            settings.merge(baseSettings(sm["base"])) { _, new in new }
        }

        var sources: [XcodeGenTarget.Source] = []
        if case .sequence(let seq)? = tm["sources"] {
            for n in seq {
                if let p = n.string { sources.append(.init(path: p, buildPhase: nil, type: nil)); continue }
                guard case .mapping(let m) = n, let p = m["path"]?.string else {
                    throw fail("\(file):\(n.mark?.line ?? line): source entry has no path")
                }
                sources.append(.init(path: p, buildPhase: m["buildPhase"]?.string, type: m["type"]?.string))
            }
        }

        guard case .mapping(let info)? = tm["info"], let infoPath = info["path"]?.string else {
            throw fail("\(file):\(line): target '\(name)' has no info.path")
        }
        var infoProps: [String: Any] = [:]
        if case .mapping(let pm)? = info["properties"] {
            for (k, v) in pm { if let key = k.string { infoProps[key] = plain(v) } }
        }

        var deps: [XcodeGenTarget.Dependency] = []
        if case .sequence(let seq)? = tm["dependencies"] {
            for n in seq {
                guard case .mapping(let m) = n else { continue }
                if let sdk = m["sdk"]?.string {
                    deps.append(.sdk(sdk))
                } else if let fw = m["framework"]?.string {
                    let embed = m["embed"]?.bool ?? true
                    deps.append(.framework(path: fw, embed: embed, codeSign: m["codeSign"]?.bool ?? embed))
                } else {
                    throw fail("\(file):\(n.mark?.line ?? line): dependency needs framework: or sdk:")
                }
            }
        }

        func scripts(_ key: String) throws -> [XcodeGenTarget.Script] {
            guard case .sequence(let seq)? = tm[key] else { return [] }
            return try seq.map { n in
                guard case .mapping(let m) = n, let s = m["script"]?.string else {
                    throw fail("\(file):\(n.mark?.line ?? line): \(key) entry has no inline script")
                }
                return .init(name: m["name"]?.string ?? "Run Script", script: s)
            }
        }

        var deployment = tm["deploymentTarget"]?.string
        if deployment == nil, case .mapping(let opts)? = top["options"], case .mapping(let dt)? = opts["deploymentTarget"] {
            deployment = dt["iOS"]?.string
        }
        var entitlements: String?
        if case .mapping(let em)? = tm["entitlements"] { entitlements = em["path"]?.string }

        return (projectName, XcodeGenTarget(
            name: name, sources: sources, infoPath: infoPath, infoProperties: infoProps, entitlementsPath: entitlements,
            settings: settings, dependencies: deps, preBuildScripts: try scripts("preBuildScripts"),
            postCompileScripts: try scripts("postCompileScripts"), deploymentTarget: deployment))
    }

    /// Node → plain value. Unquoted `true`/`false` and integers convert; everything else stays a string
    /// (so `16.0` and `1.0.0` keep their spelling).
    private static func plain(_ n: Node) -> Any {
        switch n {
        case .scalar(let s):
            if s.style == .plain {
                if s.string == "true" { return true }
                if s.string == "false" { return false }
                if let i = Int(s.string) { return i }
            }
            return s.string
        case .sequence(let seq): return seq.map(plain)
        case .mapping(let m):
            var out: [String: Any] = [:]
            for (k, v) in m { if let key = k.string { out[key] = plain(v) } }
            return out
        case .alias: return ""
        }
    }
}
