import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import XlessASC

struct Named: Codable, Sendable { var name: String }

@Test func getDecodesAndAuthenticates() async throws {
    let t = MockTransport([(200, #"{"data":[{"type":"apps","id":"1","attributes":{"name":"A"}}]}"#)])
    let c = ASCClient(credentials: testCreds, transport: t, sleep: { _ in })
    let doc: ASCDocument<[ASCResource<Named>]> = try await c.get("/v1/apps", query: [("filter[bundleId]", "a.b")])
    #expect(doc.data.first?.attributes.name == "A")
    #expect(t.requests[0].value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
    #expect(t.requests[0].url!.absoluteString.contains("filter%5BbundleId%5D=a.b"))
}

@Test func retriesOn429And5xxThenSucceeds() async throws {
    let t = MockTransport([(429, "{}"), (503, "{}"), (200, #"{"data":{"type":"x","id":"9","attributes":{"name":"ok"}}}"#)])
    let c = ASCClient(credentials: testCreds, transport: t, sleep: { _ in })
    let doc: ASCDocument<ASCResource<Named>> = try await c.get("/v1/x")
    #expect(doc.data.id == "9")
    #expect(t.requests.count == 3)
}

@Test func doesNotRetry4xxAndSurfacesAppleErrors() async throws {
    let t = MockTransport([(409, #"{"errors":[{"status":"409","code":"ENTITY_ERROR","title":"Conflict","detail":"already exists"}]}"#)])
    let c = ASCClient(credentials: testCreds, transport: t, sleep: { _ in })
    do { let _: ASCDocument<ASCResource<Named>> = try await c.get("/v1/x"); Issue.record("expected throw") }
    catch let e as ASCError {
        #expect(e.status == 409)
        #expect(e.description.contains("already exists"))
        #expect(t.requests.count == 1)
    }
}

@Test func givesUpAfterFiveAttempts() async throws {
    let t = MockTransport(Array(repeating: (500, "{}"), count: 5))
    let c = ASCClient(credentials: testCreds, transport: t, sleep: { _ in })
    await #expect(throws: ASCError.self) { let _: ASCDocument<ASCResource<Named>> = try await c.get("/v1/x") }
    #expect(t.requests.count == 5)
}

@Test func transportURLErrorIsRetriedThenSucceeds() async throws {
    let t = MockTransport(steps: [.failure(.timedOut), .failure(.networkConnectionLost),
                                  .response(200, #"{"data":{"type":"x","id":"1","attributes":{"name":"ok"}}}"#)])
    let c = ASCClient(credentials: testCreds, transport: t, sleep: { _ in })
    let doc: ASCDocument<ASCResource<Named>> = try await c.get("/v1/x")
    #expect(doc.data.id == "1")
    #expect(t.requests.count == 3)
}

@Test(arguments: [400, 401])
func clientErrorsAreNotRetried(status: Int) async throws {
    let t = MockTransport([(status, "{}")])
    let c = ASCClient(credentials: testCreds, transport: t, sleep: { _ in })
    do { let _: ASCDocument<ASCResource<Named>> = try await c.get("/v1/x"); Issue.record("expected throw") }
    catch let e as ASCError { #expect(e.status == status) }
    #expect(t.requests.count == 1)
}

@Test func backoffDoublesBetweenAttempts() async throws {
    let t = MockTransport(Array(repeating: (500, "{}"), count: 4) + [(200, #"{"data":{"type":"x","id":"1","attributes":{"name":"ok"}}}"#)])
    let rec = SleepRecorder()
    let c = ASCClient(credentials: testCreds, transport: t, sleep: rec.fn)
    let _: ASCDocument<ASCResource<Named>> = try await c.get("/v1/x")
    #expect(rec.durations == [.seconds(1), .seconds(2), .seconds(4), .seconds(8)])
}

@Test func noSleepAfterFinalAttempt() async throws {
    let t = MockTransport(Array(repeating: (500, "{}"), count: 5))
    let rec = SleepRecorder()
    let c = ASCClient(credentials: testCreds, transport: t, sleep: rec.fn)
    await #expect(throws: ASCError.self) { let _: ASCDocument<ASCResource<Named>> = try await c.get("/v1/x") }
    #expect(rec.durations.count == 4)
}

@Test func rawSendsNoAuthorizationHeader() async throws {
    let t = MockTransport([(200, "")])
    let c = ASCClient(credentials: testCreds, transport: t, sleep: { _ in })
    var req = URLRequest(url: URL(string: "https://store.example/upload")!)
    req.httpMethod = "PUT"
    let (_, resp) = try await c.raw(req)
    #expect(resp.statusCode == 200)
    #expect(t.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func postEncodesJSONBody() async throws {
    let t = MockTransport([(201, #"{"data":{"type":"x","id":"2","attributes":{"name":"n"}}}"#)])
    let c = ASCClient(credentials: testCreds, transport: t, sleep: { _ in })
    let body = ASCCreate<Named, ASCNoRelationships>(type: "x", attributes: Named(name: "n"))
    let doc: ASCDocument<ASCResource<Named>> = try await c.post("/v1/x", body: body)
    #expect(doc.data.id == "2")
    let r = t.requests[0]
    #expect(r.httpMethod == "POST")
    #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let obj = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
    let data = obj["data"] as! [String: Any]
    #expect(data["type"] as? String == "x")
    #expect((data["attributes"] as? [String: Any])?["name"] as? String == "n")
}

@Test func deleteSucceedsOn204() async throws {
    let t = MockTransport([(204, "")])
    let c = ASCClient(credentials: testCreds, transport: t, sleep: { _ in })
    try await c.delete("/v1/x/1")
    #expect(t.requests[0].httpMethod == "DELETE")
}

@Test func postOnceSendsExactlyOneRequestOn503() async throws {
    let t = MockTransport([(503, #"{"errors":[]}"#), (201, #"{"data":{"type":"x","id":"2","attributes":{"name":"n"}}}"#)])
    let rec = SleepRecorder()
    let c = ASCClient(credentials: testCreds, transport: t, sleep: rec.fn)
    let body = ASCCreate<Named, ASCNoRelationships>(type: "x", attributes: Named(name: "n"))
    do { let _: ASCDocument<ASCResource<Named>> = try await c.postOnce("/v1/x", body: body); Issue.record("expected throw") }
    catch let e as ASCError { #expect(e.status == 503) }
    #expect(t.requests.count == 1)
    #expect(rec.durations.isEmpty)
}

@Test func postOnceDoesNotRetryTransportError() async throws {
    let t = MockTransport(steps: [.failure(.timedOut), .response(201, "{}")])
    let c = ASCClient(credentials: testCreds, transport: t, sleep: { _ in })
    let body = ASCCreate<Named, ASCNoRelationships>(type: "x", attributes: Named(name: "n"))
    await #expect(throws: URLError.self) { let _: ASCDocument<ASCResource<Named>> = try await c.postOnce("/v1/x", body: body) }
    #expect(t.requests.count == 1)
}
