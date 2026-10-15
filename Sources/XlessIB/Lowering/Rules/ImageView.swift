import Foundation
import XlessCore

/// `UIImageView` (docs/research/nib-encoding.md, section 6 "UIView subclasses" and "UIImageView"; corpus `image-*`).
///
/// Keys: the common `UIView` keys (`ViewRule.encode`, including [`UITintColor`]), then [`UIImage` =
/// @`UIImageNibPlaceholder`, if an image is set (`image-none` has none)]. `image="X"` and
/// `<imageReference key="image" image="X">` give the same nib (`image-reference`, `image-reference-symbol`).
enum ImageViewRule {
    /// Attributes proven for image views: Xcode's defaults (`image-catalog-*`), each toggled (`image-no-clips`,
    /// `image-userinteraction-default`, `image-opaque-no`, `image-hugging-*`, `image-mode-*`) and the spellings Xcode
    /// does not write (`image-attrs-explicit`).
    static let attributes = ViewRule.subviewAttributes.union(["image", "catalog"])
    /// `image-background` (both, in this key order), `image-tint`, `image-tint-srgb`.
    static let colorKeys: Set<String> = ["backgroundColor", "tintColor"]
    static let imageReferenceAttributes: Set<String> = ["key", "image", "catalog"]

    static func checkSupported(_ v: IBView, lowering l: ViewNibLowering) throws {
        try ViewRule.checkCommon(v, attributes: attributes, colorKeys: colorKeys, isRoot: false, lowering: l)
        // `catalog` qualifies the `image` attribute of the same element; without it (or next to an `<imageReference>`)
        // no golden says what ibtool does.
        if let catalog = v.attributes["catalog"], v.attributes["image"] == nil {
            throw LoweringError.unsupported("attribute catalog=\"\(catalog)\" on <imageView> without an image attribute", line: v.line)
        }
        if let s = v.subviews.first { throw LoweringError.unsupported("subview inside an <imageView>", line: s.line) }
        if let ref = l.doc.element(at: v.rawPath)?.children.first(where: { $0.name == "imageReference" }) {
            try LoweringError.checkAttributes(ref.attributes, known: imageReferenceAttributes, element: "imageReference", line: ref.line)
        }
        if let image = v.image { try ImageRule.check(image, line: v.line) }
    }

    static func encode(_ v: IBView, into ref: ObjectRef, parts: ViewRule.Parts, lowering l: ViewNibLowering) throws {
        try ViewRule.encode(v, into: ref, parts: parts, lowering: l)
        if let image = v.image { l.b.set(ref, "UIImage", ImageRule.encode(image, into: l.b)) }
    }
}
