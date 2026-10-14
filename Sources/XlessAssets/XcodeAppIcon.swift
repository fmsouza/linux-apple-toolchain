import AssetKit
import Foundation
import PNG
import XlessCore

/// What actool (Xcode 27.0) emits for an Xcode 14+ single-size iOS app icon (one universal 1024x1024 PNG):
/// the 1024 icon filed under the phone and pad idioms in Assets.car, two loose fallback PNGs
/// (`<name>60x60@2x.png` 120px, `<name>76x76@2x~ipad.png` 152px) and `CFBundleIcons` / `CFBundleIcons~ipad`
/// dictionaries naming them. AssetKit's own icon glue only covers per-size icon sets.
public enum XcodeAppIcon {
    /// True for an appiconset holding exactly one universal 1024x1024 image (Xcode's default since Xcode 14).
    public static func isSingleSize(_ contentsJSON: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: contentsJSON) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return false }
        let withFiles = images.filter { ($0["filename"] as? String).map { !$0.isEmpty } ?? false }
        guard withFiles.count == 1, let image = withFiles.first else { return false }
        return image["idiom"] as? String == "universal" && image["size"] as? String == "1024x1024"
            && (image["platform"] as? String ?? "ios") == "ios"
    }

    /// The single-size image re-filed under the iphone and ipad idioms, as actool stores it.
    static func phoneAndPadImages(_ image: [String: Any]) -> [[String: Any]] {
        ["iphone", "ipad"].map { idiom in
            var copy = image
            copy["idiom"] = idiom
            copy.removeValue(forKey: "platform")
            return copy
        }
    }

    /// Info.plist keys for the icon. Xcode always writes both dictionaries; `CFBundleIconName` appears only in
    /// the dictionary of each targeted device family (UIDeviceFamily 1 = iPhone, 2 = iPad).
    public static func plistAdditions(name: String, deviceFamily: [Int]) -> [String: Any] {
        func primary(_ files: [String], named: Bool) -> [String: Any] {
            var icon: [String: Any] = ["CFBundleIconFiles": files]
            if named { icon["CFBundleIconName"] = name }
            return ["CFBundlePrimaryIcon": icon]
        }
        return [
            "CFBundleIcons": primary(["\(name)60x60"], named: deviceFamily.contains(1)),
            "CFBundleIcons~ipad": primary(["\(name)60x60", "\(name)76x76"], named: deviceFamily.contains(2)),
        ]
    }

    /// The loose fallback PNGs, downscaled from the 1024px icon.
    public static func looseFiles(name: String, icon1024: Data) throws -> [LooseFile] {
        [
            LooseFile(name: "\(name)60x60@2x.png", data: try downscale(png: icon1024, to: 120)),
            LooseFile(name: "\(name)76x76@2x~ipad.png", data: try downscale(png: icon1024, to: 152)),
        ]
    }

    /// Box-filter downscale of a PNG to a `size`x`size` opaque RGB PNG (app icons must not carry alpha).
    public static func downscale(png: Data, to size: Int) throws -> Data {
        var src = ByteStream(bytes: [UInt8](png))
        let image: PNG.Image
        do { image = try PNG.Image.decompress(stream: &src) } catch {
            throw XlessError(.assets, "cannot decode the app icon PNG: \(error)", fix: "re-export the icon as a standard PNG")
        }
        let (w, h) = image.size
        let px = image.unpack(as: PNG.RGBA<UInt8>.self)
        var out: [PNG.RGBA<UInt8>] = []
        out.reserveCapacity(size * size)
        for oy in 0..<size {
            let y0 = oy * h / size, y1 = max(y0 + 1, (oy + 1) * h / size)
            for ox in 0..<size {
                let x0 = ox * w / size, x1 = max(x0 + 1, (ox + 1) * w / size)
                var r = 0, g = 0, b = 0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let p = px[y * w + x]
                        r += Int(p.r); g += Int(p.g); b += Int(p.b)
                    }
                }
                let n = (y1 - y0) * (x1 - x0)
                out.append(.init(UInt8((r + n / 2) / n), UInt8((g + n / 2) / n), UInt8((b + n / 2) / n), 255))
            }
        }
        let resized = PNG.Image(packing: out, size: (size, size), layout: .init(format: .rgb8(palette: [], fill: nil, key: nil)))
        var dst = ByteStream()
        try resized.compress(stream: &dst)
        return Data(dst.bytes)
    }

    private struct ByteStream: PNG.BytestreamSource, PNG.BytestreamDestination {
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
