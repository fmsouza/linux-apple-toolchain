import Foundation
import Yams

public struct PlatformConfig: Sendable, Equatable, Decodable {
    public var minimumOS: String
    public var product: String
    public var entitlements: String?
    public var distribution: Distribution?
    /// Optional per-platform bundle identifier override.
    public var bundleID: String?
}

public struct ProjectConfig: Sendable, Equatable {
    public var bundleID: String
    public var teamID: String
    public var version: String
    public var build: String
    public var platforms: [Platform: PlatformConfig]
    public var assets: String?
    public var privacyManifest: String?
    public var infoPlist: String?

    public func platform(_ p: Platform) throws -> PlatformConfig {
        guard let c = platforms[p] else {
            throw XlessError(.config, "platform '\(p.rawValue)' is not configured in xless.yml", fix: "add a platforms.\(p.rawValue) entry")
        }
        return c
    }

    public func distribution(for p: Platform) -> Distribution {
        platforms[p]?.distribution ?? (p == .ios ? .appStore : .developerID)
    }

    public func bundleID(for p: Platform) -> String {
        platforms[p]?.bundleID ?? bundleID
    }
}

private struct BuildNumber: Decodable {
    let value: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = String(i) } else { value = try c.decode(String.self) }
    }
}

private struct RawConfig: Decodable {
    var bundleID: String
    var teamID: String
    var version: String
    var build: BuildNumber
    var platforms: [String: PlatformConfig]
    var assets: String?
    var privacyManifest: String?
    var infoPlist: String?
}

extension ProjectConfig {
    public static func parse(yaml: String, buildOverride: String? = nil) throws -> ProjectConfig {
        let raw: RawConfig
        do {
            raw = try YAMLDecoder().decode(RawConfig.self, from: yaml)
        } catch {
            throw XlessError(.config, "xless.yml is invalid: \(error)", fix: "see docs/xless-yml.md for the schema")
        }
        var platforms: [Platform: PlatformConfig] = [:]
        for (key, value) in raw.platforms {
            guard let p = Platform(rawValue: key) else {
                throw XlessError(.config, "unknown platform '\(key)'", fix: "use 'ios' or 'macos'")
            }
            platforms[p] = value
        }
        let config = ProjectConfig(
            bundleID: raw.bundleID, teamID: raw.teamID, version: raw.version,
            build: buildOverride ?? raw.build.value, platforms: platforms,
            assets: raw.assets, privacyManifest: raw.privacyManifest, infoPlist: raw.infoPlist)
        try config.validate()
        return config
    }

    public static func load(from url: URL, buildOverride: String? = nil) throws -> ProjectConfig {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XlessError(.config, "cannot read \(url.path)", fix: "run xless in the directory containing xless.yml or pass --project")
        }
        return try parse(yaml: text, buildOverride: buildOverride)
    }

    func validate() throws {
        if platforms.isEmpty {
            throw XlessError(.config, "no platforms configured", fix: "add platforms.ios and/or platforms.macos")
        }
        if teamID.wholeMatch(of: /[A-Z0-9]{10}/) == nil {
            throw XlessError(.config, "teamID '\(teamID)' is not a 10-character Apple team ID", fix: "copy it from developer.apple.com → Membership")
        }
        for id in [bundleID] + platforms.values.compactMap(\.bundleID) where id.wholeMatch(of: /[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+/) == nil {
            throw XlessError(.config, "bundleID '\(id)' is invalid", fix: "use reverse-DNS form, e.g. com.example.app")
        }
        if version.wholeMatch(of: /\d+(\.\d+){0,2}/) == nil {
            throw XlessError(.config, "version '\(version)' is invalid", fix: "use 1–3 dot-separated integers, e.g. 1.0.0")
        }
        if build.wholeMatch(of: /\d+(\.\d+){0,2}/) == nil {
            throw XlessError(.config, "build '\(build)' is invalid", fix: "use 1–3 dot-separated integers")
        }
        for (p, pc) in platforms {
            if DottedVersion(pc.minimumOS) == nil {
                throw XlessError(.config, "platforms.\(p.rawValue).minimumOS '\(pc.minimumOS)' is invalid", fix: "use e.g. \"17.0\"")
            }
        }
        if distribution(for: .ios) != .appStore, platforms[.ios] != nil {
            throw XlessError(.config, "iOS distribution must be app-store in milestone 1", fix: "remove platforms.ios.distribution")
        }
        if distribution(for: .macos) != .developerID, platforms[.macos] != nil {
            throw XlessError(.config, "macOS distribution must be developer-id in milestone 1 (Mac App Store .pkg is not supported)", fix: "set platforms.macos.distribution: developer-id")
        }
    }
}
