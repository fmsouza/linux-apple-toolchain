import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import XlessASC

final class MockTransport: HTTPTransport, @unchecked Sendable {
    enum Step { case response(Int, String), failure(URLError.Code) }
    var steps: [Step]
    var requests: [URLRequest] = []
    init(_ responses: [(Int, String)]) { self.steps = responses.map { .response($0.0, $0.1) } }
    init(steps: [Step]) { self.steps = steps }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body): (Int, String)
        switch steps.removeFirst() {
        case .response(let s, let b): (status, body) = (s, b)
        case .failure(let code): throw URLError(code)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// Throwaway P-256 key for tests.
import Crypto
let testCreds = ASCCredentials(keyID: "KEY123", issuerID: "iss-1", privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation)

/// Records durations passed to the injected sleep.
final class SleepRecorder: @unchecked Sendable {
    var durations: [Duration] = []
    var fn: @Sendable (Duration) async throws -> Void { { [self] d in durations.append(d) } }
}
