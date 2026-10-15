import Foundation

public enum NIBArchiveWriter {
    public static func write(_ a: NIBArchive) -> Data {
        var sections: [NIBSection: Data] = [:]
        var objs = Data()
        for o in a.objects { objs.append(contentsOf: Varint.encode(o.classNameIndex) + Varint.encode(o.valuesStart) + Varint.encode(o.valueCount)) }
        sections[.objects] = objs
        var keys = Data()
        for k in a.keys { keys.append(contentsOf: Varint.encode(k.count)); keys.append(k) }
        sections[.keys] = keys
        var vals = Data()
        for v in a.values {
            vals.append(contentsOf: Varint.encode(v.keyIndex))
            func le<T: FixedWidthInteger>(_ x: T) { withUnsafeBytes(of: x.littleEndian) { vals.append(contentsOf: $0) } }
            switch v.data {
            case .int8(let x): vals.append(0); le(x)
            case .int16(let x): vals.append(1); le(x)
            case .int32(let x): vals.append(2); le(x)
            case .int64(let x): vals.append(3); le(x)
            case .bool(let b): vals.append(b ? 5 : 4)
            case .float(let f): vals.append(6); le(f.bitPattern)
            case .double(let f): vals.append(7); le(f.bitPattern)
            case .data(let d): vals.append(8); vals.append(contentsOf: Varint.encode(d.count)); vals.append(d)
            case .null: vals.append(9)
            case .object(let r): vals.append(10); le(r)
            }
        }
        sections[.values] = vals
        var cls = Data()
        for c in a.classNames {
            cls.append(contentsOf: Varint.encode(c.name.count + 1) + Varint.encode(c.extras.count))
            for e in c.extras { withUnsafeBytes(of: e.littleEndian) { cls.append(contentsOf: $0) } }
            cls.append(c.name); cls.append(0)
        }
        sections[.classNames] = cls

        precondition(a.sectionOrder.count == 4 && Set(a.sectionOrder).count == 4,
                     "NIBArchive.sectionOrder must list each of objects, keys, values, classNames exactly once")
        var offsets: [NIBSection: Int] = [:]
        var body = Data(), cursor = 50
        for s in a.sectionOrder { offsets[s] = cursor; body.append(sections[s]!); cursor += sections[s]!.count }
        var out = Data("NIBArchive".utf8)
        func u32(_ x: Int) { withUnsafeBytes(of: UInt32(x).littleEndian) { out.append(contentsOf: $0) } }
        u32(Int(a.formatVersion)); u32(Int(a.coderVersion))
        u32(a.objects.count); u32(offsets[.objects]!)
        u32(a.keys.count); u32(offsets[.keys]!)
        u32(a.values.count); u32(offsets[.values]!)
        u32(a.classNames.count); u32(offsets[.classNames]!)
        out.append(body)
        out.append(a.trailer)
        return out
    }
}
