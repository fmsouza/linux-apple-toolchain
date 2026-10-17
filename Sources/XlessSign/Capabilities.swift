import Foundation
import XlessASC
import XlessCore

/// Bundle-ID capabilities that the app's entitlements require; a profile only carries an entitlement
/// once the matching capability is enabled on the identifier.
public enum Capabilities {
    /// Gated iOS entitlement key → App Store Connect `capabilityType`. Every entry must be a capability type that
    /// `POST /v1/bundleIdCapabilities` accepts, that is, a value of the API's `capabilityType` enum (the API rejects
    /// any other with 409 ENTITY_ERROR.ATTRIBUTE.TYPE). Checked against `CapabilityType` in Apple's OpenAPI spec 4.5.1
    /// (openapi.oas.json): all four are members, and none needs `settings`. Keys with no such type (App Attest, Declared
    /// Age Range, the increased memory limit, …) are portal-only: they are enabled by hand in the developer portal and
    /// reach the profile through the refresh in `SignStage` (ruling R13). The API cannot create or assign app groups
    /// (no app-group resource, and `CapabilitySetting.key` has no group setting): `APP_GROUPS` only enables the capability.
    public static let map: [String: String] = [
        "aps-environment": "PUSH_NOTIFICATIONS",
        "com.apple.developer.associated-domains": "ASSOCIATED_DOMAINS",
        "com.apple.developer.authentication-services.autofill-credential-provider": "AUTOFILL_CREDENTIAL_PROVIDER",
        "com.apple.security.application-groups": "APP_GROUPS",
    ]

    /// The map xless uses for `platform`. macOS enables no capability through the API, as before: every gated key is
    /// treated as portal-only, so it must already be granted by the profile (enabled by hand, picked up by the profile
    /// refresh). Its keys also differ from iOS's (`com.apple.developer.aps-environment`), so this map would not fit.
    public static func map(for platform: Platform) -> [String: String] { platform == .ios ? map : [:] }

    /// Developer-portal names of portal-only capabilities, for the refusal's fix.
    static let portalNames: [String: String] = [
        "com.apple.developer.devicecheck.appattest-environment": "App Attest",
        "com.apple.developer.declared-age-range": "Declared Age Range",
        "com.apple.developer.kernel.increased-memory-limit": "Increased Memory Limit",
        "com.apple.developer.kernel.extended-virtual-addressing": "Extended Virtual Address Space",
    ]

    /// Keys that need no capability: the ones xless sets itself and the macOS sandbox / hardened-runtime keys.
    public static func isUngated(_ key: String) -> Bool { Entitlements.managedKeys.contains(key) || Entitlements.isUngated(key) }

    /// Capability types for the mapped gated keys, and the gated keys xless cannot enable itself. Unmapped keys are
    /// not refused here: they may have been enabled manually in the portal, which `Entitlements.merge` checks
    /// against the profile.
    public static func required(entitlements: [String: Any], platform: Platform,
                                map: [String: String]? = nil) -> (types: [String], unmapped: [String]) {
        let map = map ?? Self.map(for: platform)
        var types: [String] = [], unmapped: [String] = []
        for key in entitlements.keys.sorted() where !isUngated(key) {
            if let type = map[key] { if !types.contains(type) { types.append(type) } } else { unmapped.append(key) }
        }
        return (types, unmapped)
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
