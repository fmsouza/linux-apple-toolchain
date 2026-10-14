import Foundation

public struct PNGHeader: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var colorType: UInt8
    /// PNG color types 4 (gray+alpha) and 6 (RGBA) carry an alpha channel.
    public var hasAlpha: Bool { colorType == 4 || colorType == 6 }

    public static func parse(_ png: Data) throws -> PNGHeader {
        let sig = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        guard png.count >= 26, png.prefix(8) == sig, png.subdata(in: 12..<16) == Data("IHDR".utf8) else {
            throw MachOError.unsupported("not a PNG")
        }
        return PNGHeader(width: Int(try png.u32(16, bigEndian: true)), height: Int(try png.u32(20, bigEndian: true)),
                         colorType: png[png.startIndex + 25])
    }
}

public enum ICNS {
    static let typeForWidth: [Int: String] = [16: "icp4", 32: "icp5", 64: "icp6", 128: "ic07", 256: "ic08", 512: "ic09", 1024: "ic10"]

    /// Builds an .icns from square PNGs (one per size; duplicates keep the first), largest first.
    public static func make(pngs: [Data]) throws -> Data {
        var entries: [(Int, String, Data)] = []
        for png in pngs {
            let h = try PNGHeader.parse(png)
            guard h.width == h.height, let type = typeForWidth[h.width] else {
                throw MachOError.unsupported("icon size \(h.width)x\(h.height); use 16–1024 powers of two")
            }
            if !entries.contains(where: { $0.0 == h.width }) { entries.append((h.width, type, png)) }
        }
        entries.sort { $0.0 > $1.0 }
        var body = Data()
        func be(_ v: UInt32, into d: inout Data) { var x = v.bigEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        for (_, type, png) in entries {
            body.append(Data(type.utf8)); be(UInt32(png.count + 8), into: &body); body.append(png)
        }
        var out = Data("icns".utf8)
        be(UInt32(body.count + 8), into: &out)
        out.append(body)
        return out
    }
}
