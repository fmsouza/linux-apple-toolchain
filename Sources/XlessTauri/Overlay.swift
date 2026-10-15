import Foundation
import Yams
import XlessCore

/// iOS-specific overrides in an overlay's `ios:` block.
public struct OverlayIOS: Sendable, Equatable, Decodable {
    public var product: String?
    public var minimumOS: String?
    public var entitlements: String?
}

/// A prebuilt binary that replaces a CocoaPods dependency.
public struct BinaryDependency: Sendable, Equatable, Decodable {
    public struct Fixes: Sendable, Equatable, Decodable {
        public var minimumOSVersion: String?
    }
    public var url: String
    public var sha256: String
    public var extract: String
    public var to: String
    public var fixes: Fixes?
    /// Extra linker flags this dependency needs (consumed when linking the app).
    public var linkFlags: [String]

    enum CodingKeys: String, CodingKey { case url, sha256, extract, to, fixes, linkFlags }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        sha256 = try c.decode(String.self, forKey: .sha256)
        extract = try c.decode(String.self, forKey: .extract)
        to = try c.decode(String.self, forKey: .to)
        fixes = try c.decodeIfPresent(Fixes.self, forKey: .fixes)
        linkFlags = try c.decodeIfPresent([String].self, forKey: .linkFlags) ?? []
    }
}

/// How a `project.yml` build script (other than Tauri's own) is treated.
public enum ScriptHandling: String, Sendable, Decodable { case ignore }

/// An xless overlay for a Tauri v2 iOS app (`type: tauri`). It lives outside the app repository.
public struct TauriOverlay: Sendable, Equatable {
    /// Overlay file basename without extension.
    public var name: String
    public var source: String?
    public var tauriDir: String
    public var features: [String]
    public var bundleID: String
    public var teamID: String
    /// nil (absent or `tauri`) means "take it from the Tauri config".
    public var version: String?
    /// `"dated"` or an explicit build number.
    public var build: String
    public var ios: OverlayIOS?
    public var assets: String?
    public var launchStoryboard: String?
    public var infoPlist: String?
    /// PrivacyInfo.xcprivacy for the app bundle. `OverlayLocation.load` makes it absolute (relative paths resolve
    /// against the overlay file's directory, like `source:`), so it may live outside the app repository.
    public var privacyManifest: String?
    public var linkFlags: [String]
    public var binaryDependencies: [BinaryDependency]
    public var scripts: [String: ScriptHandling]
    public var usesNonExemptEncryption: Bool?
    public var testflight: TestFlightConfig?
}

private struct BuildNumber: Decodable {
    let value: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = String(i) } else { value = try c.decode(String.self) }
    }
}

private struct Raw: Decodable {
    struct Tauri: Decodable { var dir: String?; var features: [String]? }
    var type: String
    var source: String?
    var tauri: Tauri?
    var bundleID: String
    var teamID: String
    var version: BuildNumber?
    var build: BuildNumber?
    var ios: OverlayIOS?
    var assets: String?
    var launchStoryboard: String?
    var infoPlist: String?
    var privacyManifest: String?
    var linkFlags: [String]?
    var binaryDependencies: [BinaryDependency]?
    var scripts: [String: ScriptHandling]?
    var usesNonExemptEncryption: Bool?
    var testflight: TestFlightConfig?
}

extension TauriOverlay {
    public static func parse(yaml: String, name: String) throws -> TauriOverlay {
        let raw: Raw
        do {
            raw = try YAMLDecoder().decode(Raw.self, from: yaml)
        } catch {
            throw XlessError(.config, "overlay \(name) is invalid: \(error)", fix: "see samples/HelloTauri/xless.overlay.example.yml for the schema")
        }
        guard raw.type == "tauri" else {
            throw XlessError(.config, "overlay \(name): type '\(raw.type)' is not supported", fix: "set type: tauri")
        }
        if raw.teamID.wholeMatch(of: /[A-Z0-9]{10}/) == nil {
            throw XlessError(.config, "overlay \(name): teamID '\(raw.teamID)' is not a 10-character Apple team ID", fix: "copy it from developer.apple.com → Membership")
        }
        if raw.bundleID.wholeMatch(of: /[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+/) == nil {
            throw XlessError(.config, "overlay \(name): bundleID '\(raw.bundleID)' is invalid", fix: "use reverse-DNS form, e.g. com.example.app")
        }
        let deps = raw.binaryDependencies ?? []
        for (i, d) in deps.enumerated() {
            if d.sha256.wholeMatch(of: /[0-9a-fA-F]{64}/) == nil {
                throw XlessError(.config, "overlay \(name): binaryDependencies[\(i)].sha256 is not 64 hex characters", fix: "paste the sha256 of the downloaded file")
            }
            if !d.url.hasPrefix("https://") {
                throw XlessError(.config, "overlay \(name): binaryDependencies[\(i)].url must be https", fix: "host the dependency at an https:// URL")
            }
            if d.to.hasPrefix("/") || d.to.split(separator: "/").contains("..") || d.to.isEmpty {
                throw XlessError(.config, "overlay \(name): binaryDependencies[\(i)].to '\(d.to)' must be a relative path without '..'", fix: "use a path inside the work copy, e.g. src-tauri/gen/apple/Pods/X/X.xcframework")
            }
        }
        let version = raw.version?.value
        return TauriOverlay(
            name: name, source: raw.source, tauriDir: raw.tauri?.dir ?? "src-tauri", features: raw.tauri?.features ?? [],
            bundleID: raw.bundleID, teamID: raw.teamID, version: (version == nil || version == "tauri") ? nil : version,
            build: raw.build?.value ?? "dated", ios: raw.ios, assets: raw.assets, launchStoryboard: raw.launchStoryboard,
            infoPlist: raw.infoPlist, privacyManifest: raw.privacyManifest, linkFlags: raw.linkFlags ?? [], binaryDependencies: deps, scripts: raw.scripts ?? [:],
            usesNonExemptEncryption: raw.usesNonExemptEncryption, testflight: raw.testflight)
    }
}

/// An overlay file plus where its source tree and work copy live.
public struct OverlayLocation: Sendable, Equatable {
    public var overlay: TauriOverlay
    public var sourceRoot: URL
    public var workRoot: URL

    /// Reads and parses the overlay at `url`. `sourceRoot` is `sourceOverride`, else the overlay's `source:`
    /// (`~` expanded; relative resolves against the overlay file's directory). `workRoot` is
    /// `$XLESS_WORK_ROOT` (default `~/.cache/xless/work`) + `/<overlay name>`.
    public static func load(from url: URL, sourceOverride: String? = nil, env: [String: String] = ProcessInfo.processInfo.environment) throws -> OverlayLocation {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XlessError(.config, "cannot read overlay \(url.path)", fix: "pass the path of an existing overlay file to --config")
        }
        let name = url.deletingPathExtension().lastPathComponent
        var overlay = try TauriOverlay.parse(yaml: text, name: name)
        let home = env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        func expand(_ p: String) -> String {
            p == "~" ? home : p.hasPrefix("~/") ? home + String(p.dropFirst(1)) : p
        }
        let overlayDir = url.deletingLastPathComponent()
        func resolve(_ p: String) -> URL {
            let e = expand(p)
            return (e.hasPrefix("/") ? URL(fileURLWithPath: e) : URL(fileURLWithPath: e, relativeTo: overlayDir)).standardizedFileURL
        }
        overlay.privacyManifest = overlay.privacyManifest.map { resolve($0).path }
        let sourceRoot: URL
        if let s = sourceOverride {
            sourceRoot = URL(fileURLWithPath: expand(s)).standardizedFileURL
        } else if let s = overlay.source {
            sourceRoot = resolve(s)
        } else {
            throw XlessError(.config, "overlay \(name) has no source", fix: "set source: in the overlay or pass --source <dir>")
        }
        let base = env["XLESS_WORK_ROOT"].flatMap { $0.isEmpty ? nil : expand($0) } ?? home + "/.cache/xless/work"
        let workRoot = URL(fileURLWithPath: base).appendingPathComponent(name).standardizedFileURL
        return OverlayLocation(overlay: overlay, sourceRoot: sourceRoot, workRoot: workRoot)
    }
}
