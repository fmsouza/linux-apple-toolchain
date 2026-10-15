import Foundation
import XlessCore

public enum NIBArchiveReader {
    static let magic = Data("NIBArchive".utf8)

    /// Reads the archive at `url`; an unreadable file is an `[ib]` error.
    public static func read(url: URL) throws -> NIBArchive {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw XlessError(.ib, "cannot read \(url.path): \(error.localizedDescription)", fix: "check the path")
        }
        return try read(data)
    }

    public static func read(_ data: Data) throws -> NIBArchive {
        let d = Data(data)   // zero-based indices
        guard d.count >= 50, d.prefix(10) == magic else {
            throw XlessError(.ib, "not a NIBArchive file", fix: "pass a compiled .nib file")
        }
        func u32(_ off: Int) -> UInt32 { d.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: off, as: UInt32.self)) } }
        var a = NIBArchive()
        a.formatVersion = u32(10); a.coderVersion = u32(14)
        let counts = (0..<8).map { Int(u32(18 + $0 * 4)) }
        let (oc, oo, kc, ko, vc, vo, cc, co) = (counts[0], counts[1], counts[2], counts[3], counts[4], counts[5], counts[6], counts[7])
let offsets: [(NIBSection, Int)] = [(.objects, oo), (.keys, ko), (.values, vo), (.classNames, co)]

        for (name, count, off) in [("objects", oc, oo), ("keys", kc, ko), ("values", vc, vo), ("class names", cc, co)] {
            guard off >= 50, off <= d.count else {
                throw XlessError(.ib, "NIB \(name) section offset \(off) is outside the file", fix: "the .nib file is corrupt")
            }
            // every record occupies at least one byte, so a count beyond the file size is bogus
            guard count <= d.count else {
                throw XlessError(.ib, "NIB \(name) count \(count) exceeds file size", fix: "the .nib file is corrupt")
            }
        }

        var sectionsEnd = 50
        var ends: [NIBSection: Int] = [:]
        var i = oo
        for _ in 0..<oc {
            a.objects.append(NIBObject(classNameIndex: try Varint.decode(d, at: &i), valuesStart: try Varint.decode(d, at: &i), valueCount: try Varint.decode(d, at: &i)))
        }
        sectionsEnd = max(sectionsEnd, i); ends[.objects] = i
        i = ko
        for _ in 0..<kc {
            let n = try Varint.decode(d, at: &i)
            guard n <= d.count - i else { throw truncated("key") }
            a.keys.append(d.subdata(in: i..<(i + n))); i += n
        }
        sectionsEnd = max(sectionsEnd, i); ends[.keys] = i
        i = vo
        for _ in 0..<vc {
            let key = try Varint.decode(d, at: &i)
            guard i < d.count else { throw truncated("value") }
            let type = d[i]; i += 1
            func take(_ n: Int) throws -> Data { guard n <= d.count - i else { throw truncated("value payload") }; defer { i += n }; return d.subdata(in: i..<(i + n)) }
            func le<T: FixedWidthInteger>(_ t: T.Type) throws -> T { try take(MemoryLayout<T>.size).withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) } }
            let v: NIBValueData
            switch type {
            case 0: v = .int8(try le(Int8.self))
            case 1: v = .int16(try le(Int16.self))
            case 2: v = .int32(try le(Int32.self))
            case 3: v = .int64(try le(Int64.self))
            case 4: v = .bool(false)   // tag 4 = NO, tag 5 = YES (docs/research/nib-encoding.md, "Booleans")
            case 5: v = .bool(true)
            case 6: v = .float(Float(bitPattern: try le(UInt32.self)))
            case 7: v = .double(Double(bitPattern: try le(UInt64.self)))
            case 8: let n = try Varint.decode(d, at: &i); v = .data(try take(n))
            case 9: v = .null
            case 10: v = .object(try le(UInt32.self))
            default: throw XlessError(.ib, "unknown NIB value type \(type) at byte \(i - 1)", fix: "report this .nib to the xless maintainers")
            }
            a.values.append(NIBValue(keyIndex: key, data: v))
        }
        sectionsEnd = max(sectionsEnd, i); ends[.values] = i
        i = co
        for _ in 0..<cc {
            let n = try Varint.decode(d, at: &i)
            let extraCount = try Varint.decode(d, at: &i)
            var extras: [Int32] = []
            for _ in 0..<extraCount {
                guard 4 <= d.count - i else { throw truncated("class extras") }
                extras.append(d.withUnsafeBytes { Int32(littleEndian: $0.loadUnaligned(fromByteOffset: i, as: Int32.self)) }); i += 4
            }
            guard n >= 1, n <= d.count - i else { throw truncated("class name") }
            a.classNames.append(NIBClassName(name: d.subdata(in: i..<(i + n - 1)), extras: extras)); i += n
        }
        sectionsEnd = max(sectionsEnd, i); ends[.classNames] = i
        // The writer lays sections out back to back, so only contiguous layouts can round-trip.
        // Zero-length sections only need an in-range offset; a zero-length section sharing an offset
        // with a non-empty one comes first. Among co-located empties the order is canonical (the
        // bytes are identical whichever order the writer used).
        let lengths = offsets.map { ends[$0.0]! - $0.1 }
        let ranked = offsets.enumerated().map { (sec: $0.element.0, start: $0.element.1, empty: lengths[$0.offset] == 0) }
            .sorted { ($0.start, $0.empty ? 0 : 1, $0.sec.rawValue) < ($1.start, $1.empty ? 0 : 1, $1.sec.rawValue) }
        a.sectionOrder = ranked.map(\.sec)
        var expected = 50
        for r in ranked {
            if r.empty { continue }   // range already checked above
            guard r.start == expected else { throw invalid("\(r.sec) section starts at \(r.start), expected \(expected) (sections must be contiguous)") }
            expected = ends[r.sec]!
        }
        a.trailer = d.subdata(in: sectionsEnd..<d.count)
        for (n, o) in a.objects.enumerated() {
            guard o.classNameIndex < a.classNames.count else { throw invalid("object #\(n) class index \(o.classNameIndex) out of range") }
            guard o.valuesStart <= a.values.count, o.valueCount <= a.values.count - o.valuesStart else {
                throw invalid("object #\(n) value range \(o.valuesStart)+\(o.valueCount) out of range")
            }
        }
        for (n, v) in a.values.enumerated() where v.keyIndex >= a.keys.count {
            throw invalid("value #\(n) key index \(v.keyIndex) out of range")
        }
        return a
    }

    static func invalid(_ what: String) -> XlessError {
        XlessError(.ib, "invalid NIB: \(what)", fix: "the .nib file is corrupt")
    }

    static func truncated(_ what: String) -> XlessError {
        XlessError(.ib, "truncated NIB \(what)", fix: "the .nib file is corrupt")
    }
}
