import Foundation
import XlessCore

/// The Tauri v2 config as the iOS build sees it: `tauri.conf.json` with `tauri.<platform>.conf.json` merge-patched over it.
public struct TauriConfig: @unchecked Sendable {
    public var productName: String?
    public var identifier: String
    public var version: String?
    public var beforeBuildCommand: String?
    public var frontendDist: String?
    public var iosMinimumSystemVersion: String?
    public var macOSMinimumSystemVersion: String?
    /// `bundle.macOS.entitlements`, as written (relative to the Tauri directory).
    public var macOSEntitlements: String?
    public var mainBinaryName: String?
    /// The merged JSON object.
    public var raw: [String: Any]

    public static func load(tauriDir: URL, platform: String) throws -> TauriConfig {
        func read(_ name: String) throws -> Any? {
            let url = tauriDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do {
                return try JSONSerialization.jsonObject(with: Data(contentsOf: url), options: [.fragmentsAllowed])
            } catch {
                throw XlessError(.prepare, "cannot read \(url.path): \(error.localizedDescription)", fix: "fix the JSON syntax in \(name)")
            }
        }
        guard let base = try read("tauri.conf.json") else {
            throw XlessError(.prepare, "no tauri.conf.json in \(tauriDir.path)", fix: "set tauri.dir in the overlay to the directory containing tauri.conf.json")
        }
        guard base is [String: Any] else {
            throw XlessError(.prepare, "tauri.conf.json is not a JSON object", fix: "fix tauri.conf.json")
        }
        var merged = base
        if let patch = try read("tauri.\(platform).conf.json") { merged = JSONMergePatch.apply(patch, to: merged) }
        let raw = merged as? [String: Any] ?? [:]

        guard let identifier = raw["identifier"] as? String else {
            throw XlessError(.prepare, "tauri.conf.json has no identifier", fix: "set \"identifier\" in tauri.conf.json")
        }
        var version = raw["version"] as? String
        if let v = version, v.hasSuffix(".json") {
            let pkg = tauriDir.appendingPathComponent(v).standardizedFileURL
            guard let data = try? Data(contentsOf: pkg),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let pv = obj["version"] as? String else {
                throw XlessError(.prepare, "tauri.conf.json version points at \(v), which has no readable \"version\"", fix: "put a version string in \(v) or in tauri.conf.json")
            }
            version = pv
        }
        let build = raw["build"] as? [String: Any]
        let ios = (raw["bundle"] as? [String: Any])?["iOS"] as? [String: Any]
        let mac = (raw["bundle"] as? [String: Any])?["macOS"] as? [String: Any]
        return TauriConfig(
            productName: raw["productName"] as? String, identifier: identifier, version: version,
            beforeBuildCommand: build?["beforeBuildCommand"] as? String, frontendDist: build?["frontendDist"] as? String,
            iosMinimumSystemVersion: ios?["minimumSystemVersion"] as? String,
            macOSMinimumSystemVersion: mac?["minimumSystemVersion"] as? String, macOSEntitlements: mac?["entitlements"] as? String,
            mainBinaryName: raw["mainBinaryName"] as? String, raw: raw)
    }
}
