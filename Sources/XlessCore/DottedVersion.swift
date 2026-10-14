public struct DottedVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ s: String) {
        let raw = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(raw.count), raw.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        parts = raw.map { $0! } + Array(repeating: 0, count: 3 - raw.count)
    }

    public static func < (a: DottedVersion, b: DottedVersion) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
    public var major: Int { parts[0] }
    public var description: String { parts.map(String.init).joined(separator: ".") }
}
