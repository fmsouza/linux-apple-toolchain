import Foundation
import PNG

/// In-memory adapter for swift-png's `PNG.BytestreamSource`. Lets us decode
/// PNG bytes that come from a `Data` buffer (e.g. fresh output from an SVG
/// rasteriser) without round-tripping through a temp file.
private struct MemoryBytestream: PNG.BytestreamSource {
    var bytes: [UInt8]
    var offset: Int = 0
    mutating func read(count: Int) -> [UInt8]? {
        guard offset + count <= bytes.count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }
}

/// PNG source handler: produces one bitmap rendition with BGRA-premultiplied
/// pixels. Shared by both `.imageset` (kind=.image) and `.appiconset`
/// (kind=.appIcon) paths; the caller picks the kind via the Context.
enum PNGSource {
    struct Context {
        var assetName: String
        var idiom: Idiom
        var scale: Scale?
        var appearance: Appearance?
        var gamut: Gamut
        var filename: String
        var kind: BitmapBody.Kind
    }

    static func renditions(bytes: Data, context: Context) throws -> [Rendition] {
        let (width, height, bgra) = try decodeBGRA(bytes)
        return [Rendition(
            name: context.assetName,
            idiom: context.idiom,
            scale: context.scale,
            appearance: context.appearance,
            gamut: context.gamut,
            body: .bitmap(BitmapBody(
                width: width,
                height: height,
                pixelsBGRA: bgra,
                colorSpaceID: context.gamut.colorSpaceID,
                kind: context.kind,
                renditionName: context.filename
            ))
        )]
    }

    /// Decode PNG bytes to BGRA-premultiplied pixels. Shared with SVGSource's
    /// rasterised fanout, which feeds PNG bytes returned by the SVG rasteriser
    /// straight through this path.
    static func decodeBGRA(_ bytes: Data) throws -> (UInt32, UInt32, [UInt8]) {
        var blob = MemoryBytestream(bytes: [UInt8](bytes))
        let image = try PNG.Image.decompress(stream: &blob)
        let rgba: [PNG.RGBA<UInt8>] = image.unpack(as: PNG.RGBA<UInt8>.self)
        let width = UInt32(image.size.x)
        let height = UInt32(image.size.y)
        var out = [UInt8](repeating: 0, count: rgba.count * 4)
        for i in 0..<rgba.count {
            let px = rgba[i]
            let a = UInt16(px.a)
            let r = UInt8((UInt16(px.r) * a + 127) / 255)
            let g = UInt8((UInt16(px.g) * a + 127) / 255)
            let b = UInt8((UInt16(px.b) * a + 127) / 255)
            let base = i * 4
            out[base + 0] = b
            out[base + 1] = g
            out[base + 2] = r
            out[base + 3] = px.a
        }
        return (width, height, out)
    }
}
