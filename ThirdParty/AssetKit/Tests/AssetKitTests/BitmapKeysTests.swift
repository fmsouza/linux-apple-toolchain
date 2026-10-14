import Foundation
import Testing
@testable import AssetKit

/// BITMAPKEYS descriptors: `[1, 0, 4 + 4n, n]` followed by one u32 per KEYFORMAT attribute (n of them), each a
/// bitmask of the values that attribute takes across the asset's renditions (bit v for value v), except
/// appearance, identifier, element and part, which are always -1. Expected values come from actool 27.0
/// (Xcode 27A266a) output and from `assetutil --update-bitmap`, which rewrites the index from the renditions.
@Suite("BITMAPKEYS")
struct BitmapKeysTests {
    private static let none: UInt32 = 0xFFFF_FFFF

    private func bitmap(_ name: String, _ idiom: Idiom, _ scale: Scale?, kind: BitmapBody.Kind, dark: Bool = false) -> Rendition {
        Rendition(
            name: name, idiom: idiom, scale: scale,
            appearance: dark ? .dark : nil, gamut: nil,
            body: .bitmap(BitmapBody(width: 1, height: 1, pixelsBGRA: [0, 0, 0, 255], colorSpaceID: 1, kind: kind, renditionName: "x.png"))
        )
    }

    private func words(_ d: Data) -> [UInt32] {
        stride(from: 0, to: d.count, by: 4).map { i in (0..<4).reduce(UInt32(0)) { $0 | UInt32(d[d.startIndex + i + $1]) << (8 * $1) } }
    }

    @Test("Single-size app icon filed under phone and pad at 1x (assetutil --update-bitmap)")
    func appIcon() {
        let d = BitmapKeys.descriptor(renditions: [
            bitmap("AppIcon", .iphone, .x1, kind: .appIcon),
            bitmap("AppIcon", .ipad, .x1, kind: .appIcon),
        ])
        #expect(words(d) == [1, 0, 40, 9, Self.none, 1, 2, 6, 1, 2, Self.none, Self.none, Self.none])
    }

    @Test("Universal color without scale (assetutil --update-bitmap)")
    func color() {
        let d = BitmapKeys.descriptor(renditions: [
            Rendition(name: "Accent", idiom: .universal, scale: nil, appearance: nil, gamut: nil,
                      body: .color(ColorBody(red: 1, green: 0, blue: 0, alpha: 1, colorSpaceID: 1))),
        ])
        #expect(words(d) == [1, 0, 40, 9, Self.none, 1, 1, 1, 1, 1, Self.none, Self.none, Self.none])
    }

    @Test("Image at 1x/2x/3x, a dark 2x and an iPad 2x (actool 27.0)")
    func image() {
        let d = BitmapKeys.descriptor(renditions: [
            bitmap("Pic", .universal, .x1, kind: .image),
            bitmap("Pic", .universal, .x2, kind: .image),
            bitmap("Pic", .universal, .x3, kind: .image),
            bitmap("Pic", .universal, .x2, kind: .image, dark: true),
            bitmap("Pic", .ipad, .x2, kind: .image),
        ])
        #expect(words(d) == [1, 0, 40, 9, Self.none, 1, 0xE, 5, 1, 1, Self.none, Self.none, Self.none])
    }

    @Test("Every asset name gets an entry, colors included, keyed by its identifier")
    func entriesCoverColors() {
        let layout = CARLayout(renditions: [
            bitmap("AppIcon", .iphone, .x1, kind: .appIcon),
            Rendition(name: "Accent", idiom: .universal, scale: nil, appearance: nil, gamut: nil,
                      body: .color(ColorBody(red: 1, green: 0, blue: 0, alpha: 1, colorSpaceID: 1))),
        ])
        let keys = BitmapKeys.entries(for: layout.assets).map(\.key)
        #expect(Set(keys) == [FacetKeys.nameHash("AppIcon") & 0xFFFF, FacetKeys.nameHash("Accent") & 0xFFFF])
    }
}
