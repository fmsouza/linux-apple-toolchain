import Foundation
import XlessCore

/// `UIImageNibPlaceholder`: an image view's image (docs/research/nib-encoding.md, section 6 "UIImageNibPlaceholder").
///
/// Keys, in order: `UIImageWidth`, `UIImageHeight` (float), `UIResourceName`, `UISystemSymbolResourceName`,
/// `UISymbolImageConfiguration` = nil, `UIResourceCatalogName` = nil.
/// - Asset image (present, missing or without a `<resources><image>`): 1.0 × 1.0, symbol name nil
///   (`image-catalog-*`, `image-missing`, `image-no-resource`, `image-resource-size`). ibtool never reads the catalog
///   and prints no warning for a missing image.
/// - SF Symbol (`catalog="system"`): 0.0 × 0.0, `UISystemSymbolResourceName` = the `UIResourceName` string
///   (`image-system-symbol`, `-no-resource`, `image-reference-symbol`). ibtool gives this form only to symbol names it
///   knows and the asset form to any other name; the compiler accepts the names of `image-symbol-grid`.
///
/// Equal images are one shared placeholder; an asset and a symbol with the same name are two (`image-uniquing`).
enum ImageRule {
    /// The SF Symbol names proven by `image-symbol-grid` at every flag set (scripts/ib-corpus/gen.py `SYMBOLS`).
    static let verifiedSymbols: Set<String> = [
        "star.fill", "heart.fill", "house.fill", "person.fill", "person.circle.fill", "gear", "bolt.fill", "sun.max.fill",
        "moon.fill", "cloud.fill", "flame.fill", "music.note", "camera.fill", "photo", "map.fill", "cart.fill", "bag.fill",
        "book.fill", "bell.fill", "lock.fill", "checkmark.circle.fill", "xmark", "magnifyingglass", "paperplane.fill",
        "envelope.fill", "phone.fill", "message.fill", "square.and.arrow.up", "plus", "play.fill", "gamecontroller.fill",
        "airplane", "car.fill", "globe", "leaf.fill", "sparkles", "apple.logo", "swift",
    ]

    /// Refuses images whose encoding no golden proves.
    static func check(_ image: IBImageReference, line: Int?) throws {
        guard !image.name.isEmpty else { throw LoweringError.unsupported("image view with an empty image name", line: line) }
        switch image.catalog {
        case nil: break
        case "system":
            guard verifiedSymbols.contains(image.name) else {
                throw LoweringError.openQuestion("SF Symbol \"\(image.name)\" (ibtool encodes only the symbols it knows as symbols; the verified names are listed in docs/research/nib-encoding.md)",
                                                 line: line, fix: "use a verified symbol, or export the symbol into the asset catalog and reference it by name")
            }
        case let other?:
            throw LoweringError.unsupported("image catalog=\"\(other)\" (supported: asset images, catalog=\"system\")", line: line)
        }
    }

    static func encode(_ image: IBImageReference, into b: ArchiveBuilder) -> ObjectRef {
        let symbol = image.catalog == "system"
        return b.unique("UIImageNibPlaceholder|\(symbol ? "symbol" : "asset")|\(image.name)") {
            let r = b.object("UIImageNibPlaceholder")
            let size: Float = symbol ? 0 : 1
            b.set(r, "UIImageWidth", .float(size))
            b.set(r, "UIImageHeight", .float(size))
            let name = b.string(image.name)
            b.set(r, "UIResourceName", name)
            if symbol { b.set(r, "UISystemSymbolResourceName", name) } else { b.set(r, "UISystemSymbolResourceName", .null) }
            b.set(r, "UISymbolImageConfiguration", .null)
            b.set(r, "UIResourceCatalogName", .null)
            return r
        }
    }
}
