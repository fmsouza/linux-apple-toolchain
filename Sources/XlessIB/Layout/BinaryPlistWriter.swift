import Foundation

/// A `bplist00` writer that reproduces the bytes ibtool writes for a compiled storyboard's `Info.plist`
/// (docs/research/nib-encoding.md, section 2). Foundation's writer shares equal strings and orders dictionary keys by
/// hash, while ibtool's output keeps every string as its own object, unless it is the same object twice (`tagged` /
/// `ref`: the storyboard identifier's entry point, `vc-storyboard-identifier`), and keeps the dictionary order it was given.
///
/// Layout: objects are flattened depth-first (a dictionary, then all its keys, then all its values); object references
/// and offset-table entries use the fewest bytes (1, 2, 4 or 8) that hold the object count and the offset table's own
/// offset; the 32-byte trailer is 6 zero bytes, the two sizes, then object count, top object (0) and offset-table
/// offset as 8-byte big-endian integers.
public enum BinaryPlistWriter {
    public indirect enum Value: Equatable, Sendable {
        case string(String)
        case int(Int)
        /// Entries in the order they are written.
        case dict([Entry])
        /// A value that a later `ref` with the same tag refers to (one object, referenced twice).
        case tagged(String, Value)
        /// Another reference to the object of a `tagged` value; adds no object.
        case ref(String)
    }

    public struct Entry: Equatable, Sendable {
        public var key: Value
        public var value: Value
        public init(_ key: Value, _ value: Value) { self.key = key; self.value = value }
    }

    public static func write(_ top: Value) -> Data {
        // Every value is its own object except a `ref`, numbered in `emitTree` order.
        let count = objectCount(top)
        let refSize = byteCount(UInt64(count))
        var tags: [String: Int] = [:]
        var counter = 0
        func assign(_ v: Value) {
            switch v {
            case .ref: return
            case .tagged(let tag, let inner): tags[tag] = counter; assign(inner)
            case .dict(let entries):
                counter += 1
                for e in entries { assign(e.key) }
                for e in entries { assign(e.value) }
            case .string, .int: counter += 1
            }
        }
        assign(top)

        var out = Data("bplist00".utf8)
        var offsets: [Int] = []
        var nextRef = 0
        func emit(_ v: Value) {
            if case .tagged(_, let inner) = v { return emit(inner) }
            if case .ref = v { return }
            offsets.append(out.count)
            nextRef += 1
            switch v {
            case .tagged, .ref: break
            case .int(let i):
                out.append(contentsOf: intBytes(i))
            case .string(let s):
                if s.utf8.allSatisfy({ $0 < 0x80 }) {
                    marker(0x50, count: s.utf8.count)
                    out.append(contentsOf: s.utf8)
                } else {
                    let units = Array(s.utf16)
                    marker(0x60, count: units.count)
                    for u in units { out.append(UInt8(u >> 8)); out.append(UInt8(u & 0xFF)) }
                }
            case .dict(let entries):
                marker(0xD0, count: entries.count)
                // refs: keys are numbered right after this dict, values after all keys' subtrees
                var refs: [Int] = []
                var r = nextRef
                for v in entries.map(\.key) + entries.map(\.value) {
                    if case .ref(let tag) = v { refs.append(tags[tag]!) } else { refs.append(r); r += objectCount(v) }
                }
                for ref in refs { out.append(contentsOf: bigEndian(UInt64(ref), size: refSize)) }
            }
        }
        func marker(_ base: UInt8, count: Int) {
            if count < 15 { out.append(base | UInt8(count)) } else { out.append(base | 0x0F); out.append(contentsOf: intBytes(count)) }
        }
        func emitTree(_ v: Value) {
            if case .tagged(_, let inner) = v { return emitTree(inner) }
            emit(v)
            if case .dict(let entries) = v {
                for e in entries { emitTree(e.key) }
                for e in entries { emitTree(e.value) }
            }
        }
        emitTree(top)

        let tableOffset = out.count
        let offsetSize = byteCount(UInt64(tableOffset))
        for o in offsets { out.append(contentsOf: bigEndian(UInt64(o), size: offsetSize)) }
        out.append(contentsOf: [UInt8](repeating: 0, count: 6))
        out.append(UInt8(offsetSize))
        out.append(UInt8(refSize))
        out.append(contentsOf: bigEndian(UInt64(count), size: 8))
        out.append(contentsOf: bigEndian(0, size: 8))
        out.append(contentsOf: bigEndian(UInt64(tableOffset), size: 8))
        return out
    }

    static func objectCount(_ v: Value) -> Int {
        switch v {
        case .dict(let entries): return 1 + entries.reduce(0) { $0 + objectCount($1.key) + objectCount($1.value) }
        case .tagged(_, let inner): return objectCount(inner)
        case .ref: return 0
        case .string, .int: return 1
        }
    }

    static func byteCount(_ x: UInt64) -> Int {
        x <= 0xFF ? 1 : x <= 0xFFFF ? 2 : x <= 0xFFFF_FFFF ? 4 : 8
    }

    static func intBytes(_ i: Int) -> [UInt8] {
        if i < 0 { return [0x13] + bigEndian(UInt64(bitPattern: Int64(i)), size: 8) }
        let size = byteCount(UInt64(i))
        let exp: UInt8 = size == 1 ? 0 : size == 2 ? 1 : size == 4 ? 2 : 3
        return [0x10 | exp] + bigEndian(UInt64(i), size: size)
    }

    static func bigEndian(_ x: UInt64, size: Int) -> [UInt8] {
        (0..<size).map { UInt8(truncatingIfNeeded: x >> (8 * UInt64(size - 1 - $0))) }
    }
}
