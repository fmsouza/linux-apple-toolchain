import Foundation
import XlessCore

public enum Entitlements {
    /// Provisioning profiles are CMS-signed XML plists; read the embedded plist without CMS parsing.
    public static func extract(fromProfile data: Data) throws -> [String: Any] {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else {
            throw XlessError(.sign, "provisioning profile has no embedded plist", fix: "delete the profile in App Store Connect and re-run")
        }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let dict = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
              let ents = dict["Entitlements"] as? [String: Any] else {
            throw XlessError(.sign, "provisioning profile plist lacks Entitlements", fix: "delete the profile in App Store Connect and re-run")
        }
        return ents
    }

    /// The team that issued a profile: its team-identifier entitlement, else the application-identifier prefix.
    static func team(ofProfile p: [String: Any]) -> String? {
        if let t = p["com.apple.developer.team-identifier"] as? String, !t.isEmpty { return t }
        let appID = (p["application-identifier"] as? String) ?? (p["com.apple.application-identifier"] as? String)
        return appID?.split(separator: ".", maxSplits: 1).first.map(String.init)
    }

    /// The API key is scoped to one team, so a wrong `teamID` in xless.yml would otherwise sign and upload fine and
    /// only fail in App Store Connect processing (invalid code-signing entitlements).
    public static func checkTeam(profile: [String: Any], teamID: String) throws {
        guard let team = team(ofProfile: profile) else {
            throw XlessError(.sign, "the provisioning profile names no team (no team-identifier or application-identifier)",
                             fix: "delete the profile in App Store Connect and re-run")
        }
        if team != teamID {
            throw XlessError(.sign, "xless.yml teamID \(teamID) ≠ team \(team) of the App Store Connect key", fix: "set teamID: \(team) in xless.yml")
        }
    }

    /// Keys xless sets itself; everything else in `user` must be granted by the profile.
    static let managedKeys: Set<String> = ["application-identifier", "com.apple.application-identifier",
                                           "com.apple.developer.team-identifier", "get-task-allow", "beta-reports-active"]

    /// macOS sandbox / hardened-runtime keys that are not gated by a provisioning profile.
    static let ungatedKeys: Set<String> = ["com.apple.security.app-sandbox", "com.apple.security.inherit",
                                           "com.apple.security.print", "com.apple.security.automation.apple-events"]
    static let ungatedPrefixes = ["com.apple.security.cs.", "com.apple.security.network.", "com.apple.security.files.",
                                  "com.apple.security.device.", "com.apple.security.personal-information."]

    static func isUngated(_ key: String) -> Bool {
        ungatedKeys.contains(key) || ungatedPrefixes.contains { key.hasPrefix($0) }
    }

    public static func merge(user: [String: Any], profile: [String: Any], platform: Platform,
                             teamID: String, bundleID: String) throws -> [String: Any] {
        for key in user.keys.sorted() where !managedKeys.contains(key) && profile[key] == nil
            && !isUngated(key) {
            throw XlessError(.sign, "entitlement '\(key)' is not granted by the provisioning profile",
                             fix: "enable the matching capability for \(bundleID) at developer.apple.com/account/resources/identifiers, then re-run")
        }
        var out = user.filter { !managedKeys.contains($0.key) }
        let appID = "\(teamID).\(bundleID)"
        out["com.apple.developer.team-identifier"] = teamID
        switch platform {
        case .ios:
            out["application-identifier"] = appID
            out["get-task-allow"] = false
            if profile["beta-reports-active"] as? Bool == true { out["beta-reports-active"] = true }
        case .macos:
            out["com.apple.application-identifier"] = appID
        }
        return out
    }
}
