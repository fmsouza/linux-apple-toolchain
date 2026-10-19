import Foundation

/// A supported Xcode release, described by versions.env's `XCODE_*` table. The Apple Swift and BuildMachineOSBuild
/// values were measured once on the maintainer's Mac (black-box); nothing at run time executes an Apple tool.
public struct KnownXcode: Equatable, Sendable {
    public let build: String
    public let shortVersion: String
    public let appleSwift: String
    public let buildMachineOSBuild: String
    /// SHA-256s of the Xcode_<version>.xip downloads of this release (empty until recorded).
    public let xipSHA256: [String]

    public init(build: String, shortVersion: String, appleSwift: String, buildMachineOSBuild: String, xipSHA256: [String]) {
        self.build = build; self.shortVersion = shortVersion; self.appleSwift = appleSwift
        self.buildMachineOSBuild = buildMachineOSBuild; self.xipSHA256 = xipSHA256
    }
}

public enum KnownXcodes {
    /// `KEY=value` lines; values unquoted or double-quoted; `#` starts a comment line, or follows a quoted value.
    public static func parseEnv(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), let close = value.dropFirst().firstIndex(of: "\"") {
                value = String(value[value.index(after: value.startIndex)..<close])
            } else if let hash = value.range(of: " #") {
                value = value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            out[key] = value
        }
        return out
    }

    public static func load(versionsEnv: URL) throws -> [KnownXcode] {
        guard let text = try? String(contentsOf: versionsEnv, encoding: .utf8) else {
            throw XlessError(.sdk, "cannot read \(versionsEnv.path)", fix: "reinstall xless (see README) or set XLESS_SHARE")
        }
        let env = parseEnv(text)
        let builds = (env["XCODE_RELEASES"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        return try builds.map { b in
            func need(_ prefix: String) throws -> String {
                guard let v = env["\(prefix)_\(b)"], !v.isEmpty else {
                    throw XlessError(.sdk, "versions.env lists Xcode \(b) but has no \(prefix)_\(b)", fix: "add \(prefix)_\(b)=… to versions.env")
                }
                return v
            }
            return KnownXcode(
                build: b, shortVersion: try need("XCODE_SHORT"), appleSwift: try need("XCODE_APPLE_SWIFT"),
                buildMachineOSBuild: try need("XCODE_BUILD_MACHINE_OS"),
                xipSHA256: (env["XCODE_XIP_SHA256_\(b)"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
        }
    }
}
