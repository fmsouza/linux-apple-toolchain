import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ASCErrorItem: Codable, Sendable {
    public var status: String?
    public var code: String?
    public var title: String?
    public var detail: String?
}

public struct ASCError: Error, CustomStringConvertible, Sendable {
    public var status: Int
    public var items: [ASCErrorItem]
    public var description: String {
        let msgs = items.map { [$0.code, $0.title, $0.detail].compactMap { $0 }.joined(separator: ": ") }
        return "App Store Connect HTTP \(status)" + (msgs.isEmpty ? "" : " — " + msgs.joined(separator: "; "))
    }
}

public struct ASCClient: Sendable {
    let credentials: ASCCredentials
    let transport: HTTPTransport
    let baseURL: URL
    let sleep: @Sendable (Duration) async throws -> Void
    static let maxAttempts = 5

    public init(credentials: ASCCredentials, transport: HTTPTransport = URLSessionTransport(),
                baseURL: URL = URL(string: "https://api.appstoreconnect.apple.com")!,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.credentials = credentials; self.transport = transport; self.baseURL = baseURL; self.sleep = sleep
    }

    public func get<T: Decodable>(_ path: String, query: [(String, String)] = []) async throws -> T {
        try decode(await send("GET", path, query: query, body: nil))
    }

    public func post<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        try decode(await send("POST", path, query: [], body: JSONEncoder().encode(body)))
    }

    /// Single attempt, never retried: for non-idempotent creates where a retry could duplicate a scarce resource.
    public func postOnce<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        try decode(await send("POST", path, query: [], body: JSONEncoder().encode(body), maxAttempts: 1))
    }

    public func patch<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        try decode(await send("PATCH", path, query: [], body: JSONEncoder().encode(body)))
    }

    public func delete(_ path: String) async throws {
        _ = try await send("DELETE", path, query: [], body: nil)
    }

    /// Sends a pre-built request (e.g. upload PUTs to Apple's storage URLs) with the same retry policy and no auth header.
    public func raw(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withRetry { try await transport.send(request) }
    }

    func decode<T: Decodable>(_ data: Data) throws -> T {
        if T.self == ASCEmpty.self, data.isEmpty { return ASCEmpty() as! T }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func send(_ method: String, _ path: String, query: [(String, String)], body: Data?, maxAttempts: Int = ASCClient.maxAttempts) async throws -> Data {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        let (data, _) = try await withRetry(maxAttempts: maxAttempts) {
            var req = URLRequest(url: comps.url!)
            req.httpMethod = method
            req.setValue("Bearer \(try JWT.appStoreConnect(credentials))", forHTTPHeaderField: "Authorization")
            if let body {
                req.httpBody = body
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            return try await transport.send(req)
        }
        return data
    }

    func withRetry(maxAttempts: Int = ASCClient.maxAttempts, _ op: () async throws -> (Data, HTTPURLResponse)) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            let result: (Data, HTTPURLResponse)
            do { result = try await op() } catch let e as URLError {
                if attempt >= maxAttempts { throw e }
                try await sleep(.seconds(1 << (attempt - 1)))
                continue
            }
            let (data, response) = result
            if (200..<300).contains(response.statusCode) { return result }
            let retryable = response.statusCode == 429 || response.statusCode >= 500
            if !retryable || attempt >= maxAttempts {
                struct Envelope: Decodable { var errors: [ASCErrorItem]? }
                let items = (try? JSONDecoder().decode(Envelope.self, from: data))?.errors ?? []
                throw ASCError(status: response.statusCode, items: items)
            }
            try await sleep(.seconds(1 << (attempt - 1)))
        }
    }
}
