import Foundation
import XlessCore

/// `xless tauri inspect`: a read-only, stable text report of what a Tauri build would do. One `key: value` per line,
/// sections in a fixed order, lists sorted or in project order; nothing in it depends on the machine (no absolute paths).
public enum InspectReport {
    /// `swiftPackages` is nil when `cargo metadata` has not run yet. `nextBuild` is nil without App Store Connect credentials.
    /// `scripts` maps a script name to `built-in`, `ignore` or `UNHANDLED`; `scriptTexts` (`builtInScripts`) holds the
    /// text of the built-in ones, printed below them as `  | ` lines because xless executes none of it but the xcode-script step.
    public static func make(resolved r: ResolvedTauri, overlay: TauriOverlay, contract: TauriContract.Detected,
                            scripts: [String: String], scriptTexts: [String: String] = [:], swiftPackages: [String]?, nextBuild: String?) -> String {
        var out: [String] = []
        func section(_ name: String, _ lines: [String]) { out.append("[\(name)]"); out += lines; out.append("") }
        func list(_ items: [String]) -> String { items.isEmpty ? "(none)" : items.joined(separator: ", ") }
        let ios = r.config.platforms[.ios]

        section("project", [
            "overlay: \(overlay.name)",
            "bundleID: \(r.config.bundleID)",
            "teamID: \(r.config.teamID)",
            "version: \(r.config.version)",
            "product: \(ios?.product ?? "(none)")",
            "minimumOS: \(ios?.minimumOS ?? "(none)")",
            "target: \(r.target.name)",
            "features: \(list(overlay.features))",
            "entitlements: \(ios?.entitlements ?? "(none)")",
            "infoPlist: \(r.config.infoPlist ?? "(none)")",
            "assets: \(r.config.assets ?? "(none)")",
            "launchStoryboard: \(r.config.launchStoryboard ?? "(none)")",
            "privacyManifest: \(overlay.privacyManifest.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "(none)")",
            "usesNonExemptEncryption: \(r.config.usesNonExemptEncryption.map { String($0) } ?? "(unset)")",
        ])

        section("contract", [
            "supported: \(TauriContract.supported).x",
            "tauri: \(contract.tauri ?? "(not found)")",
            "cli: \(contract.cli ?? "(not found)")",
            "status: \(contract.inContract ? "in contract" : "OFF CONTRACT")",
        ])

        section("sources", [
            "tauriDir: \(r.tauriDir)",
            "appleDir: \(r.appleDir)",
            "frontendDist: \(r.tauri.frontendDist ?? "(none)")",
            "beforeBuildCommand: \(r.tauri.beforeBuildCommand ?? "(none)")",
            "targetSources: \(list(r.target.sources.map(\.path).sorted()))",
        ])

        var libraries: [String] = [], sdk: [String] = [], frameworks: [String] = []
        for dep in r.target.dependencies {
            switch dep {
            case .framework(let path, _, _):
                let file = (path as NSString).lastPathComponent
                if file == "libapp.a" { continue }   // cargo's staticlib is linked in place
                if file.hasPrefix("lib"), let dot = file.lastIndex(of: ".") { libraries.append(String(file[file.index(file.startIndex, offsetBy: 3)..<dot])) }
                else { frameworks.append((file as NSString).deletingPathExtension) }
            case .sdk(let item):
                if item.hasPrefix("lib"), let dot = item.lastIndex(of: ".") { libraries.append(String(item[item.index(item.startIndex, offsetBy: 3)..<dot])) }
                else { sdk.append(item.hasSuffix(".framework") ? String(item.dropLast(".framework".count)) : item) }
            }
        }
        let flags = overlay.linkFlags + overlay.binaryDependencies.flatMap(\.linkFlags)
        section("link", [
            "libraries: \(list(Array(Set(libraries)).sorted()))",
            "frameworks: \(list(Array(Set(frameworks)).sorted()))",
            "sdkFrameworks: \(list(Array(Set(sdk)).sorted()))",
            "linkFlags: \(list(flags))",
            "libraryPaths: \(NativeLink.setting("LIBRARY_SEARCH_PATHS", in: r.target.settings) ?? "(none)")",
            "headerPaths: \(NativeLink.setting("HEADER_SEARCH_PATHS", in: r.target.settings) ?? "(none)")",
            "swiftPackages: \(swiftPackages.map { list($0.sorted()) } ?? "(run xless build to discover)")",
        ])

        let deps = overlay.binaryDependencies.sorted { $0.to < $1.to }
        section("binaryDependencies", deps.isEmpty ? ["(none)"] : deps.map {
            "\(($0.to as NSString).lastPathComponent): \($0.url) sha256=\($0.sha256.lowercased()) extract=\($0.extract) to=\($0.to)"
        })

        section("scripts", scripts.isEmpty ? ["(none)"] : scripts.keys.sorted().flatMap { name -> [String] in
            guard let text = scriptTexts[name] else { return ["\(name): \(scripts[name]!)"] }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { "  | \($0)" }
            return ["\(name): \(scripts[name]!) (\(ScriptPolicy.builtInNote))"] + (lines.last == "  | " ? lines.dropLast() : lines[...])
        })

        section("build", [
            "scheme: \(r.config.buildScheme == .dated ? "dated" : "fixed")",
            "number: \(r.config.buildScheme == .dated ? "(chosen when a build starts)" : r.config.build)",
            "next: \(nextBuild ?? "(needs App Store Connect credentials)")",
        ])
        out.removeLast()   // no trailing blank line
        return out.joined(separator: "\n") + "\n"
    }

    /// Script name → `built-in`, `ignore` or `UNHANDLED`; the report prints an unmapped script instead of refusing it.
    public static func scripts(target: XcodeGenTarget, overlay: TauriOverlay) -> [String: String] {
        Dictionary(ScriptPolicy.classify(target: target, overlay: overlay).map { ($0.name, $0.handling ?? "UNHANDLED") }, uniquingKeysWith: { $1 })
    }

    /// Script name → full text, for the built-in scripts (see `make`).
    public static func builtInScripts(target: XcodeGenTarget, overlay: TauriOverlay) -> [String: String] {
        Dictionary(ScriptPolicy.classify(target: target, overlay: overlay).filter { $0.handling == "built-in" }.map { ($0.name, $0.script) },
                   uniquingKeysWith: { $1 })
    }
}
