import Foundation
import PNG
import XlessCore

/// `copypng` on Linux (`xless shim copypng`): Swift Build's `CopyPNGFile` rule copies every `.png` resource with it
/// (`copypng [-compress] [-strip-PNG-text] <in> <out>`, from `COMPRESS_PNG_FILES` / `STRIP_PNG_TEXT`, both YES by
/// default for iOS). Xcode's `copypng` runs `pngcrush -iphone` when given either option, which writes
/// iPhone-optimized ("CgBI") PNGs for 8-bit RGB and RGBA images. Behaviour taken black-box from Xcode 27.0's tool
/// (docs/research/react-native-ios-contract.md, "Gate G3/G4"):
/// - no option: a plain copy;
/// - 8-bit RGB or RGBA, not interlaced: BGRA with premultiplied alpha (`(c·a + 127) / 255`), color type 6, raw deflate
///   data, a `CgBI` chunk `50 00 20 02` (RGBA source) or `50 00 20 06` (RGB source) before `IHDR`; text chunks are
///   dropped with `-strip-PNG-text`. The pixels are the same as Xcode's; the compressed bytes are not (another deflate);
/// - 16-bit RGB and RGBA (text chunks allowed) are copied unchanged with libpng's warning.
/// Other color types, interlacing and ancillary chunks other than text (`pngcrush` rewrites `sRGB`/`gAMA`/`tRNS`…
/// in ways not reproduced) are refused with exit 70 and the argv, as `XcrunShim`.
public enum CopyPNGShim {
    public struct Unsupported: Error, CustomStringConvertible, Equatable {
        public let argv: [String]
        public let reason: String
        public var description: String { "copypng shim: unsupported call (\(reason)): copypng \(argv.joined(separator: " "))" }
    }

    public struct Result: Equatable {
        public var output: Data
        public var stderr: String
    }

    static let textChunks: Set<String> = ["tEXt", "zTXt", "iTXt"]
    static let sixteenBitWarning = "libpng warning: Warning: Input PNG does not have an 8 bit input depth.  Please convert your PNG to 8-bit for optimal performance on iPhone OS.\n"

    /// Parses the argv: the options and the input and output paths.
    public static func parse(_ args: [String]) throws -> (compress: Bool, stripText: Bool, input: String, output: String) {
        var compress = false, strip = false, paths: [String] = []
        for a in args {
            switch a {
            case "-compress": compress = true
            case "-strip-PNG-text": strip = true
            case _ where a.hasPrefix("-"): throw Unsupported(argv: args, reason: "option \(a)")
            default: paths.append(a)
            }
        }
        guard paths.count == 2 else { throw Unsupported(argv: args, reason: "needs an input and an output") }
        return (compress, strip, paths[0], paths[1])
    }

    /// The output file for `png` copied with these options.
    public static func convert(_ png: Data, compress: Bool, stripText: Bool, argv: [String]) throws -> Result {
        guard compress || stripText else { return Result(output: png, stderr: "") }
        func refuse(_ reason: String) -> Unsupported { Unsupported(argv: argv, reason: reason) }
        let chunks = try Self.chunks(png, refuse)
        guard let ihdr = chunks.first, ihdr.type == "IHDR", ihdr.data.count == 13 else { throw refuse("no IHDR chunk") }
        let depth = ihdr.data[8], colorType = ihdr.data[9], interlace = ihdr.data[12]
        guard depth == 8 || depth == 16, colorType == 2 || colorType == 6 else {
            throw refuse("color type \(colorType) at bit depth \(depth) (only 8- and 16-bit RGB and RGBA are measured)")
        }
        guard interlace == 0 else { throw refuse("an interlaced image") }
        let ancillary = chunks.map(\.type).filter { !["IHDR", "PLTE", "IDAT", "IEND"].contains($0) }
        if let other = ancillary.first(where: { !textChunks.contains($0) }) { throw refuse("a \(other) chunk") }
        // 16-bit: Xcode's copypng leaves the file as it is (text chunks too) and prints libpng's warning.
        if depth == 16 { return Result(output: png, stderr: sixteenBitWarning) }
        if !ancillary.isEmpty, !stripText { throw refuse("text chunks without -strip-PNG-text") }

        var source = Bytes(bytes: [UInt8](png))
        let image: PNG.Image
        do { image = try PNG.Image.decompress(stream: &source) } catch { throw refuse("undecodable PNG: \(error)") }
        let pixels = image.unpack(as: PNG.RGBA<UInt8>.self).map { p -> PNG.RGBA<UInt8> in
            func pre(_ c: UInt8) -> UInt8 { UInt8((Int(c) * Int(p.a) + 127) / 255) }
            return .init(pre(p.r), pre(p.g), pre(p.b), p.a)
        }
        let optimized = PNG.Image(packing: pixels, size: image.size, layout: .init(format: .bgra8(palette: [], fill: nil)))
        var out = Bytes()
        do { try optimized.compress(stream: &out, level: 9) } catch { throw refuse("cannot encode: \(error)") }
        return Result(output: try patchCgBI(Data(out.bytes), sourceHasAlpha: colorType == 6, refuse), stderr: "")
    }

    struct Chunk { var type: String; var data: Data; var range: Range<Int> }

    static func chunks(_ png: Data, _ refuse: (String) -> Unsupported) throws -> [Chunk] {
        let bytes = [UInt8](png)
        guard bytes.count >= 8, bytes[0..<8] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else { throw refuse("not a PNG") }
        var out: [Chunk] = [], i = 8
        while i + 12 <= bytes.count {
            let n = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            guard i + 12 + n <= bytes.count else { throw refuse("a truncated chunk") }
            let type = String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self)
            out.append(Chunk(type: type, data: Data(bytes[(i + 8)..<(i + 8 + n)]), range: i..<(i + 12 + n)))
            i += 12 + n
            if type == "IEND" { break }
        }
        if out.first?.type == "CgBI" { throw refuse("an iPhone-optimized (CgBI) input") }
        return out
    }

    /// Xcode's `CgBI` chunk data: `50 00 20` then 02 for an RGBA source, 06 for an RGB one (the output is RGBA either way).
    static func patchCgBI(_ png: Data, sourceHasAlpha: Bool, _ refuse: (String) -> Unsupported) throws -> Data {
        var bytes = [UInt8](png)
        guard bytes.count > 20, String(decoding: bytes[12..<16], as: UTF8.self) == "CgBI",
              bytes[8..<12] == [0, 0, 0, 4] else { throw refuse("the encoder wrote no CgBI chunk") }
        bytes.replaceSubrange(16..<20, with: [0x50, 0x00, 0x20, sourceHasAlpha ? 0x02 : 0x06])
        let crc = CRC32.checksum(bytes[12..<20])
        bytes.replaceSubrange(20..<24, with: [UInt8(crc >> 24), UInt8(crc >> 16 & 0xff), UInt8(crc >> 8 & 0xff), UInt8(crc & 0xff)])
        return Data(bytes)
    }

    struct Bytes: PNG.BytestreamSource, PNG.BytestreamDestination {
        var bytes: [UInt8] = []
        var offset = 0
        mutating func read(count: Int) -> [UInt8]? {
            guard offset + count <= bytes.count else { return nil }
            defer { offset += count }
            return Array(bytes[offset..<offset + count])
        }
        mutating func write(_ buffer: [UInt8]) -> Void? { bytes += buffer; return () }
    }
}

/// CRC-32 (ISO 3309, as PNG chunks use).
enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var c: UInt32 = 0xFFFFFFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}
