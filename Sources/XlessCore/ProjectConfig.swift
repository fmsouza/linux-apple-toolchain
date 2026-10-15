import Foundation
import Yams

public struct PlatformConfig: Sendable, Equatable, Decodable {
    public var minimumOS: String
    public var product: String
    public var entitlements: String?
    public var distribution: Distribution?
    /// Optional per-platform bundle identifier override.
    public var bundleID: String?

    public init(minimumOS: String, product: String, entitlements: String? = nil, distribution: Distribution? = nil, bundleID: String? = nil) {
        self.minimumOS = minimumOS; self.product = product; self.entitlements = entitlements
        self.distribution = distribution; self.bundleID = bundleID
    }
}

/// Optional `testflight:` block: deliver each uploaded build to internal TestFlight groups.
public struct TestFlightConfig: Sendable, Equatable, Decodable {
    public var groups: [String]
    public var whatToTest: String?
    /// Locale of the "What to Test" text.
    public var locale: String

    public init(groups: [String], whatToTest: String? = nil, locale: String = "en-US") {
        self.groups = groups; self.whatToTest = whatToTest; self.locale = locale
    }

    enum CodingKeys: String, CodingKey { case groups, whatToTest, locale }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decode([String].self, forKey: .groups)
        whatToTest = try c.decodeIfPresent(String.self, forKey: .whatToTest)
        locale = try c.decodeIfPresent(String.self, forKey: .locale) ?? "en-US"
    }
}

/// How `build` is validated: `.fixed` is 1–3 dot-separated integers; `.dated` is `<version>.<YYYYMMDDNN>` (Tauri overlays).
public enum BuildScheme: Sendable, Equatable { case fixed, dated }

public struct ProjectConfig: Sendable, Equatable {
    public var bundleID: String
    public var teamID: String
    public var version: String
    public var build: String
    public var platforms: [Platform: PlatformConfig]
    public var assets: String?
    public var privacyManifest: String?
    public var infoPlist: String?
    /// iOS launch-screen storyboard (`.storyboard`), relative to the project; compiled in the `assets` stage.
    public var launchStoryboard: String? = nil
    public var testflight: TestFlightConfig? = nil
    /// Value stamped as `ITSAppUsesNonExemptEncryption` (export compliance) when set.
    public var usesNonExemptEncryption: Bool? = nil
    public var buildScheme: BuildScheme = .fixed

    public init(bundleID: String, teamID: String, version: String, build: String, platforms: [Platform: PlatformConfig],
                assets: String? = nil, privacyManifest: String? = nil, infoPlist: String? = nil, launchStoryboard: String? = nil,
                testflight: TestFlightConfig? = nil, usesNonExemptEncryption: Bool? = nil, buildScheme: BuildScheme = .fixed) {
        self.bundleID = bundleID; self.teamID = teamID; self.version = version; self.build = build; self.platforms = platforms
        self.assets = assets; self.privacyManifest = privacyManifest; self.infoPlist = infoPlist
        self.launchStoryboard = launchStoryboard; self.testflight = testflight
        self.usesNonExemptEncryption = usesNonExemptEncryption; self.buildScheme = buildScheme
    }

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
    var launchStoryboard: String?
    var testflight: TestFlightConfig?
    var usesNonExemptEncryption: Bool?
}

extension ProjectConfig {
    public static func parse(yaml: String, buildOverride: String? = nil, buildScheme: BuildScheme = .fixed) throws -> ProjectConfig {
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
            assets: raw.assets, privacyManifest: raw.privacyManifest, infoPlist: raw.infoPlist,
            launchStoryboard: raw.launchStoryboard, testflight: raw.testflight,
            usesNonExemptEncryption: raw.usesNonExemptEncryption, buildScheme: buildScheme)
        try config.validate()
        return config
    }

    public static func load(from url: URL, buildOverride: String? = nil) throws -> ProjectConfig {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XlessError(.config, "cannot read \(url.path)", fix: "run xless in the directory containing xless.yml or pass --project")
        }
        return try parse(yaml: text, buildOverride: buildOverride)
    }

    public func validate() throws {
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
        switch buildScheme {
        case .fixed:
            if build.wholeMatch(of: /\d+(\.\d+){0,2}/) == nil {
                throw XlessError(.config, "build '\(build)' is invalid", fix: "use 1–3 dot-separated integers")
            }
        case .dated:
            // `<version>.<YYYYMMDDNN>` of this very version: anything else could sort above the dated builds of the version.
            let prefix = version + "."
            if !build.hasPrefix(prefix) || build.dropFirst(prefix.count).wholeMatch(of: /20\d{6}(0[1-9]|[1-9]\d)/) == nil {
                throw XlessError(.config, "build '\(build)' is invalid for a dated build of version \(version)",
                                 fix: "use <version>.<YYYYMMDDNN>, e.g. \(version).2026101501 (NN is 01–99), also for --build-number/XLESS_BUILD_NUMBER")
            }
        }
        for (p, pc) in platforms {
            if DottedVersion(pc.minimumOS) == nil {
                throw XlessError(.config, "platforms.\(p.rawValue).minimumOS '\(pc.minimumOS)' is invalid", fix: "use e.g. \"17.0\"")
            }
        }
        if let sb = launchStoryboard, !sb.hasSuffix(".storyboard") || sb == ".storyboard" || sb.hasSuffix("/.storyboard") {
            throw XlessError(.config, "launchStoryboard '\(sb)' is not a .storyboard file", fix: "point launchStoryboard at the launch screen's .storyboard, e.g. Resources/LaunchScreen.storyboard")
        }
        if let tf = testflight { try Self.validate(tf) }
        if distribution(for: .ios) != .appStore, platforms[.ios] != nil {
            throw XlessError(.config, "iOS distribution must be app-store in milestone 1", fix: "remove platforms.ios.distribution")
        }
        if distribution(for: .macos) != .developerID, platforms[.macos] != nil {
            throw XlessError(.config, "macOS distribution must be developer-id in milestone 1 (Mac App Store .pkg is not supported)", fix: "set platforms.macos.distribution: developer-id")
        }
    }

    private static func validate(_ tf: TestFlightConfig) throws {
        if tf.groups.isEmpty {
            throw XlessError(.config, "testflight.groups is empty", fix: "list at least one internal TestFlight group, e.g. groups: [\"Internal\"], or remove the testflight block")
        }
        var seen = Set<String>()
        for g in tf.groups {
            if g.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw XlessError(.config, "testflight.groups contains an empty name", fix: "give every group a name")
            }
            if !seen.insert(g).inserted {
                throw XlessError(.config, "testflight.groups lists '\(g)' twice", fix: "remove the duplicate")
            }
        }
        if let w = tf.whatToTest {
            if w.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw XlessError(.config, "testflight.whatToTest is empty", fix: "write the text testers should see, or remove the key")
            }
            if w.count > 4000 {
                throw XlessError(.config, "testflight.whatToTest is \(w.count) characters; App Store Connect allows at most 4000", fix: "shorten the text")
            }
        }
        if tf.locale.wholeMatch(of: /[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*/) == nil {
            throw XlessError(.config, "testflight.locale '\(tf.locale)' is not a locale code", fix: "use e.g. en-US")
        }
    }
}
