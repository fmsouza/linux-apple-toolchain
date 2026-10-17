import Testing
import Foundation
@testable import XlessIB

/// Order-preserving `bplist00` reader for the shapes ibtool writes (dict, ASCII/UTF-16 string, integer); test-only.
/// An object referenced more than once is read as `tagged` at its first reference (keys before values, as the writer
/// numbers them) and `ref` at the others.
private func readBinaryPlist(_ d: Data) throws -> BinaryPlistWriter.Value {
    let b = [UInt8](d)
    guard b.count >= 40, Array(b.prefix(8)) == Array("bplist00".utf8) else { throw CocoaError(.propertyListReadCorrupt) }
    let t = b.count - 32
    func be(_ off: Int, _ n: Int) -> Int { (0..<n).reduce(0) { $0 << 8 | Int(b[off + $1]) } }
    let offSize = Int(b[t + 6]), refSize = Int(b[t + 7])
    let count = be(t + 8, 8), top = be(t + 16, 8), table = be(t + 24, 8)
    func offset(_ i: Int) -> Int { be(table + i * offSize, offSize) }
    func length(_ m: UInt8, _ p: inout Int) -> Int {
        if m & 0x0F != 0x0F { return Int(m & 0x0F) }
        let n = 1 << Int(b[p] & 0x0F); defer { p += 1 + n }
        return be(p + 1, n)
    }
    var refCount: [Int: Int] = [:], seen = Set<Int>()
    func countRefs(_ i: Int) {
        refCount[i, default: 0] += 1
        guard refCount[i] == 1, i < count else { return }
        var p = offset(i)
        let m = b[p]; p += 1
        if m >> 4 == 0xD { let n = length(m, &p); for k in 0..<(2 * n) { countRefs(be(p + k * refSize, refSize)) } }
    }
    countRefs(top)
    func obj(_ i: Int) throws -> BinaryPlistWriter.Value {
        guard (refCount[i] ?? 0) > 1 else { return try plain(i) }
        guard seen.insert(i).inserted else { return .ref("o\(i)") }
        return .tagged("o\(i)", try plain(i))
    }
    func plain(_ i: Int) throws -> BinaryPlistWriter.Value {
        guard i < count else { throw CocoaError(.propertyListReadCorrupt) }
        var p = offset(i)
        let m = b[p]; p += 1
        switch m >> 4 {
        case 0x1: return .int(be(p, 1 << Int(m & 0x0F)))   // 8 bytes: the bit pattern (smart shifts drop the overflow)
        case 0x5: let n = length(m, &p); return .string(String(decoding: b[p..<(p + n)], as: UTF8.self))
        case 0x6:
            let n = length(m, &p)
            return .string(String(decoding: (0..<n).map { UInt16(b[p + 2 * $0]) << 8 | UInt16(b[p + 2 * $0 + 1]) }, as: UTF16.self))
        case 0xD:
            let n = length(m, &p)
            let keys = (0..<n).map { be(p + $0 * refSize, refSize) }
            let vals = (0..<n).map { be(p + (n + $0) * refSize, refSize) }
            let k = try keys.map(obj), v = try vals.map(obj)
            return .dict(zip(k, v).map { .init($0, $1) })
        default: throw CocoaError(.propertyListReadCorrupt)
        }
    }
    return try obj(top)
}

private func goldenInfoPlists() throws -> [URL] {
    let e = FileManager.default.enumerator(at: corpusRoot.appendingPathComponent("golden"), includingPropertiesForKeys: nil)!
    return e.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "Info.plist" }.sorted { $0.path < $1.path }
}

@Test func binaryPlistWriterRoundTripsEveryGoldenInfoPlist() throws {
    let plists = try goldenInfoPlists()
    #expect(plists.count > 200)
    for url in plists {
        let bytes = try Data(contentsOf: url)
        #expect(BinaryPlistWriter.write(try readBinaryPlist(bytes)) == bytes, "\(url.path)")
    }
}

@Test func storyboardcInfoPlistMatchesGoldens() throws {
    for url in try goldenInfoPlists() {
        let bytes = try Data(contentsOf: url)
        let plist = try #require(try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
        let entry = try #require(plist["UIStoryboardDesignatedEntryPointIdentifier"] as? String)
        // golden/<case>/<flagset>.storyboardc/Info.plist: the case's view controller says which form applies
        let name = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        let doc = try StoryboardParser.parse(url: corpusRoot.appendingPathComponent("\(name).storyboard"))
        let vc = doc.scenes[0].viewController
        let identifier = vc.attributes["storyboardIdentifier"]
        #expect(entry == identifier ?? "UIViewController-\(vc.id)", "\(url.path)")
        #expect(StoryboardcLayout.infoPlist(vcID: vc.id, storyboardIdentifier: identifier) == bytes, "\(url.path)")
    }
}

@Test func binaryPlistWriterWidensOffsetsAndEncodesUnicode() throws {
    let long = String(repeating: "x", count: 300)
    let v = BinaryPlistWriter.Value.dict([.init(.string("k"), .string(long)), .init(.string("é"), .int(70000))])
    let bytes = BinaryPlistWriter.write(v)
    #expect(try readBinaryPlist(bytes) == v)
    #expect(bytes[bytes.count - 26] == 2)   // offset entries need 2 bytes past 255
    let parsed = try #require(try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
    #expect(parsed["k"] as? String == long)
    #expect(parsed["é"] as? Int == 70000)
}

@Test func binaryPlistWriterWidensObjectRefsAndEncodesNegativeIntegers() throws {
    // 1 + 2 * 130 = 261 objects: object references need 2 bytes.
    let entries = (0..<130).map { BinaryPlistWriter.Entry(.string("key\($0)"), .int($0 - 65)) }
    let v = BinaryPlistWriter.Value.dict(entries)
    let bytes = BinaryPlistWriter.write(v)
    #expect(bytes[bytes.count - 25] == 2)   // object-ref size
    #expect(try readBinaryPlist(bytes) == v)
    let parsed = try #require(try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
    #expect(parsed.count == 130)
    #expect(parsed["key0"] as? Int == -65)
    #expect(parsed["key129"] as? Int == 64)
    #expect(BinaryPlistWriter.write(.int(-1)).dropFirst(8).prefix(9) == Data([0x13, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
}
