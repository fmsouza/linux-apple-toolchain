import Foundation
import XlessCore

/// The Tauri versions whose iOS build xless reproduces: the ones docs/research/tauri-ios-contract.md was measured with.
/// A different `tauri` crate or `@tauri-apps/cli` minor version may generate a different Xcode project or need a
/// different environment, so it is refused until the contract is re-measured.
public enum TauriContract {
    /// major.minor of both the `tauri` crate and `@tauri-apps/cli`.
    public static let supported = "2.12"

    /// The detected versions; nil where they cannot be read.
    public struct Detected: Equatable, Sendable {
        public var tauri: String?
        public var cli: String?
        public init(tauri: String?, cli: String?) { self.tauri = tauri; self.cli = cli }
        public var inContract: Bool { tauri.map(majorMinor) == supported && cli.map(majorMinor) == supported }
    }

    /// Reads both versions without judging them. `source` is the app root; `tauriDir` is relative to it.
    public static func detect(source: URL, tauriDir: String = "src-tauri") -> Detected {
        let dir = source.appendingPathComponent(tauriDir)
        let tauri = cargoLock(from: dir, upTo: source)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }.flatMap { tauriVersion(cargoLock: $0) }
        let cli = (try? cliVersion(appRoot: dir.deletingLastPathComponent())) ?? nil
        return Detected(tauri: tauri, cli: cli)
    }

    /// `source` is the app root; `tauriDir` is relative to it.
    public static func check(source: URL, tauriDir: String = "src-tauri") throws {
        let found = detect(source: source, tauriDir: tauriDir)
        guard let tauri = found.tauri else {
            throw XlessError(.prepare, "cannot read the tauri crate version from Cargo.lock in \(tauriDir)",
                             fix: "commit Cargo.lock (run `cargo generate-lockfile` in \(tauriDir))")
        }
        guard let cli = found.cli else {
            throw XlessError(.prepare, "cannot find the @tauri-apps/cli version (no lockfile entry and no package.json dependency)",
                             fix: "add @tauri-apps/cli \(supported).x to package.json and commit its lockfile")
        }
        guard found.inContract else {
            throw XlessError(.prepare, "Tauri \(tauri) / CLI \(cli) is outside the contract xless supports (\(supported).x)",
                             fix: "re-run `make tauri-reference` on a Mac and update docs/research/tauri-ios-contract.md + TauriContract.supported")
        }
    }

    /// The nearest Cargo.lock from `dir` up to `root` (a workspace keeps it at its root).
    static func cargoLock(from dir: URL, upTo root: URL) -> URL? {
        var d = dir.standardizedFileURL
        let stop = root.standardizedFileURL.path
        while true {
            let f = d.appendingPathComponent("Cargo.lock")
            if FileManager.default.fileExists(atPath: f.path) { return f }
            if d.path == stop || d.path == "/" || !d.path.hasPrefix(stop) { return nil }
            d = d.deletingLastPathComponent()
        }
    }

    static func tauriVersion(cargoLock text: String) -> String? {
        text.firstMatch(of: /name = "tauri"\r?\nversion = "([^"]*)"/).map { String($0.1) }
    }

    /// The installed `@tauri-apps/cli` version from `pnpm-lock.yaml`, `package-lock.json` or `yarn.lock` (v1 or berry),
    /// else the version in package.json's range (`~2.12.0` → `2.12.0`).
    static func cliVersion(appRoot: URL) throws -> String? {
        func read(_ name: String) -> String? { try? String(contentsOf: appRoot.appendingPathComponent(name), encoding: .utf8) }
        if let pnpm = read("pnpm-lock.yaml"),
           let m = pnpm.firstMatch(of: /'?@tauri-apps\/cli@([0-9][^'(:\s]*)'?:/) ?? pnpm.firstMatch(of: /'@tauri-apps\/cli':\s*\n\s*specifier:[^\n]*\n\s*version: ([0-9][^\s(]*)/) {
            return String(m.1)
        }
        if let npm = read("package-lock.json"), let json = try? JSONSerialization.jsonObject(with: Data(npm.utf8)) as? [String: Any] {
            let packages = json["packages"] as? [String: Any], deps = json["dependencies"] as? [String: Any]
            let entry = (packages?["node_modules/@tauri-apps/cli"] ?? deps?["@tauri-apps/cli"]) as? [String: Any]
            if let v = entry?["version"] as? String { return v }
        }
        if let yarn = read("yarn.lock"),
           let m = yarn.firstMatch(of: /(?m)^"?@tauri-apps\/cli@[^\n]*:\n\s+version:? "?([0-9][^"\n]*)"?/) {
            return String(m.1)
        }
        if let pkg = read("package.json"), let json = try? JSONSerialization.jsonObject(with: Data(pkg.utf8)) as? [String: Any] {
            for key in ["devDependencies", "dependencies"] {
                if let range = (json[key] as? [String: Any])?["@tauri-apps/cli"] as? String,
                   let m = range.firstMatch(of: /[0-9]+\.[0-9]+(\.[0-9]+)?/) {
                    return String(m.0)
                }
            }
        }
        return nil
    }

    static func majorMinor(_ v: String) -> String { v.split(separator: ".").prefix(2).joined(separator: ".") }
}
