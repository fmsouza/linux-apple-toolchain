import PNG

/// In-memory swift-png byte stream for tests.
struct PNGBytes: PNG.BytestreamSource, PNG.BytestreamDestination {
    var bytes: [UInt8] = []
    var offset = 0
    mutating func read(count: Int) -> [UInt8]? {
        guard offset + count <= bytes.count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }
    mutating func write(_ buffer: [UInt8]) -> Void? { bytes += buffer; return () }
}
