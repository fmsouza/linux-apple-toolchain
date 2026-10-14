import Foundation

/// BITMAPKEYS tree: per-asset index of which attribute values the asset's
/// renditions use. CoreUI consults it during `UIImage(named:)` resolution and
/// `assetutil --validate-file` checks it against the RENDITIONS tree
/// ("invalid bitmapindex" when they disagree).
///
/// Structure (verified against actool 27.0 / CoreUI 1010 output and against
/// `assetutil --update-bitmap`, which rewrites the index from the renditions):
/// - The tree is `isPathInternal = true` and uses a `blockSize` of 1024.
/// - Each leaf entry's "key" slot is an INLINE u32 NameIdentifier (not a
///   block pointer like other trees).
/// - Every asset name has an entry, colors included.
/// - Each value is a little-endian u32 descriptor:
///   `[1, 0, 4 + 4n, n, mask_0 … mask_(n-1)]`, n = number of KEYFORMAT
///   attributes. `mask_i` has bit `v` set for every value `v` that attribute
///   `i` takes across the asset's renditions; appearance, identifier, element
///   and part are always `0xFFFFFFFF`.
enum BitmapKeys {
    /// KEYFORMAT attributes actool leaves unconstrained (all bits set).
    static let unconstrained: Set<AttributeID> = [.appearance, .identifier, .element, .part]

    /// The descriptor for one asset, from that asset's renditions.
    static func descriptor(renditions: [Rendition], keyFormat: [AttributeID] = v1KeyFormat) -> Data {
        let keys = renditions.map(RenditionKey.init(rendition:))
        var w = ByteWriter()
        w.writeLE(UInt32(1))
        w.writeLE(UInt32(0))
        w.writeLE(UInt32(4 + 4 * keyFormat.count))
        w.writeLE(UInt32(keyFormat.count))
        for attribute in keyFormat {
            if unconstrained.contains(attribute) {
                w.writeLE(UInt32.max)
                continue
            }
            let values = keys.map { $0.value(of: attribute) }
            // RenditionKey only emits small values (scale <= 3, idiom <= 7, dimension2 <= 1, the rest 0).
            precondition(values.allSatisfy { $0 < 32 }, "BITMAPKEYS cannot index \(attribute) value >= 32")
            w.writeLE(values.reduce(UInt32(0)) { $0 | 1 << UInt32($1) })
        }
        return w.data
    }

    /// One BITMAPKEYS entry per asset: `(NameIdentifier, descriptor bytes)`.
    static func entries(for assets: [AssetFacts]) -> [BOMTree.InlineKeyEntry] {
        assets.map { asset in
            BOMTree.InlineKeyEntry(
                key: FacetKeys.nameHash(asset.name) & 0xFFFF,
                value: descriptor(renditions: asset.renditions)
            )
        }
    }
}
