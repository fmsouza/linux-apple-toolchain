import Foundation
import XlessASC
import XlessCore

/// Bundle-ID capabilities that the app's entitlements require; a profile only carries an entitlement
/// once the matching capability is enabled on the identifier.
public enum Capabilities {
    /// Gated entitlement key → App Store Connect `capabilityType`. Every entry must be a capability type that
    /// `POST /v1/bundleIdCapabilities` accepts, that is, a value of the API's `capabilityType` enum (the API rejects
    /// any other with 409 ENTITY_ERROR.ATTRIBUTE.TYPE). The increased memory limit is portal-only and has no
    /// such type, so it is not mapped: it is enabled by hand in the developer portal and reaches the profile
    /// through the refresh in `SignStage`. The table is empty for now.
    public static let map: [String: String] = [:]

    /// Keys that need no capability: the ones xless sets itself and the macOS sandbox / hardened-runtime keys.
    public static func isUngated(_ key: String) -> Bool { Entitlements.managedKeys.contains(key) || Entitlements.isUngated(key) }

    /// Capability types for the mapped gated keys, and the gated keys xless cannot enable itself. Unmapped keys are
    /// not refused here: they may have been enabled manually in the portal, which `Entitlements.merge` checks
    /// against the profile.
    public static func required(entitlements: [String: Any], platform: Platform,
                                map: [String: String] = Capabilities.map) -> (types: [String], unmapped: [String]) {
        var types: [String] = [], unmapped: [String] = []
        for key in entitlements.keys.sorted() where !isUngated(key) {
            if let type = map[key] { if !types.contains(type) { types.append(type) } } else { unmapped.append(key) }
        }
        return (types, unmapped)
    }

    /// Gated keys the profile does not grant (candidates for a profile refresh).
    static func missing(from profile: [String: Any], user: [String: Any]) -> [String] {
        user.keys.sorted().filter { !isUngated($0) && profile[$0] == nil }
    }

    struct Attributes: Codable, Sendable { var capabilityType: String }
    struct Relationships: Codable, Sendable { var bundleId: ASCToOne }

    /// Enables every missing capability in `types`; true if any was created (the profile must then be regenerated).
    public static func ensure(_ types: [String], bundleIDResourceID: String, client: ASCClient) async throws -> Bool {
        if types.isEmpty { return false }
        // This relationship endpoint does not accept `limit` (ASC returns 400 PARAMETER_ERROR.ILLEGAL), so send no query.
        let existing: ASCDocument<[ASCResource<Attributes>]> = try await client.get("/v1/bundleIds/\(bundleIDResourceID)/bundleIdCapabilities")
        let have = Set(existing.data.map(\.attributes.capabilityType))
        var created = false
        for type in types where !have.contains(type) {
            let body = ASCCreate<Attributes, Relationships>(
                type: "bundleIdCapabilities", attributes: .init(capabilityType: type),
                relationships: .init(bundleId: .init(.init(type: "bundleIds", id: bundleIDResourceID))))
            let _: ASCDocument<ASCResource<Attributes>> = try await client.post("/v1/bundleIdCapabilities", body: body)
            created = true
        }
        return created
    }
}
