import Testing
import Foundation
@testable import XlessSign
@testable import XlessASC
@testable import XlessCore

private let testMap = ["com.apple.developer.associated-domains": "ASSOCIATED_DOMAINS"]

@Test func mappedKeyNeedsItsCapability() {
    let r = Capabilities.required(entitlements: ["com.apple.developer.associated-domains": ["applinks:example.com"]], platform: .ios, map: testMap)
    #expect(r.types == ["ASSOCIATED_DOMAINS"])
    #expect(r.unmapped.isEmpty)
}

@Test func memoryLimitKeyIsPortalOnlyAndUnmapped() {
    let key = "com.apple.developer.kernel.increased-memory-limit"
    #expect(Capabilities.map[key] == nil)
    let r = Capabilities.required(entitlements: [key: true], platform: .ios)
    #expect(r.types.isEmpty)
    #expect(r.unmapped == [key])
}

@Test func managedAndUngatedKeysNeedNoCapability() {
    let ents: [String: Any] = ["get-task-allow": false, "application-identifier": "x", "com.apple.security.app-sandbox": true,
                               "com.apple.security.network.client": true]
    let r = Capabilities.required(entitlements: ents, platform: .macos)
    #expect(r.types.isEmpty && r.unmapped.isEmpty)
}

@Test func unknownGatedKeyIsReportedNotRefused() {
    let r = Capabilities.required(entitlements: ["com.apple.developer.foo": true], platform: .ios)
    #expect(r.types.isEmpty)
    #expect(r.unmapped == ["com.apple.developer.foo"])
}

private func client(_ t: MockTransport) -> ASCClient { ASCClient(credentials: testCreds, transport: t, sleep: { _ in }) }

@Test func ensureEnablesMissingCapability() async throws {
    let t = MockTransport([(200, #"{"data":[{"type":"bundleIdCapabilities","id":"X","attributes":{"capabilityType":"PUSH_NOTIFICATIONS"}}]}"#),
                           (201, #"{"data":{"type":"bundleIdCapabilities","id":"N","attributes":{"capabilityType":"ASSOCIATED_DOMAINS"}}}"#)])
    let changed = try await Capabilities.ensure(["ASSOCIATED_DOMAINS"], bundleIDResourceID: "B1", client: client(t))
    #expect(changed)
    #expect(t.requests.count == 2)
    #expect(t.requests[0].url!.path == "/v1/bundleIds/B1/bundleIdCapabilities")
    #expect(URLComponents(url: t.requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "limit" } != true)
    #expect(t.requests[1].httpMethod == "POST")
    #expect(t.requests[1].url!.path == "/v1/bundleIdCapabilities")
    let json = try JSONSerialization.jsonObject(with: t.requests[1].httpBody!) as! NSDictionary
    let expected: NSDictionary = ["data": ["type": "bundleIdCapabilities",
                                           "attributes": ["capabilityType": "ASSOCIATED_DOMAINS"],
                                           "relationships": ["bundleId": ["data": ["type": "bundleIds", "id": "B1"]]]]]
    #expect(json == expected)
}

@Test func ensureLeavesPresentCapabilityAlone() async throws {
    let t = MockTransport([(200, #"{"data":[{"type":"bundleIdCapabilities","id":"X","attributes":{"capabilityType":"ASSOCIATED_DOMAINS"}}]}"#)])
    let changed = try await Capabilities.ensure(["ASSOCIATED_DOMAINS"], bundleIDResourceID: "B1", client: client(t))
    #expect(!changed)
    #expect(t.requests.count == 1)
}

@Test func ensureWithNothingRequiredMakesNoRequests() async throws {
    let t = MockTransport([])
    #expect(try await Capabilities.ensure([], bundleIDResourceID: "B1", client: client(t)) == false)
    #expect(t.requests.isEmpty)
}
