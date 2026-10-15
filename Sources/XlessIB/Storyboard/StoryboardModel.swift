import Foundation

public struct IBRect: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Lossless element tree: every element, attributes verbatim, in document order.
/// `line` is the line of the element's start tag.
public struct IBRawElement: Equatable, Sendable {
    public var name: String
    public var attributes: [String: String]
    public var children: [IBRawElement]
    public var line: Int
    /// Character content, verbatim (entities decoded); recorded only for `<string>` elements.
    public var text: String? = nil
}

public struct IBLayoutGuide: Equatable, Sendable {
    public var id: String
    public var key: String
    public var attributes: [String: String]
    public var rawPath: [Int]
}

public struct IBColor: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case system(String)
        case named(String)
        case rgba(Double, Double, Double, Double, String?, String?)
        case white(Double, Double, String?, String?)
        /// A color element with none of the typed forms (e.g. legacy `cocoaTouchSystemColor` only).
        /// Lowering rules decide what to do with `rawAttributes`.
        case other
    }
    public var value: Value
    public var rawAttributes: [String: String]
    /// Child-index path from `IBDocument.raw` to this element (see `IBDocument.element(at:)`).
    public var rawPath: [Int]
}

public struct IBConstraint: Equatable, Sendable {
    public var id: String
    /// firstItem, firstAttribute, secondItem, secondAttribute, constant, multiplier, priority, relation, ... (verbatim)
    public var attributes: [String: String]
    public var line: Int
    public var rawPath: [Int]
}

/// An image view's image: from `image`/`catalog` attributes or an `<imageReference key="image">` element.
public struct IBImageReference: Equatable, Sendable {
    public var name: String
    /// `"system"` for SF Symbols, nil for asset-catalog images.
    public var catalog: String?
    public init(name: String, catalog: String?) { self.name = name; self.catalog = catalog }
}

public struct IBView: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case view, imageView, label }
    public var kind: Kind
    public var id: String
    public var key: String?
    public var attributes: [String: String]
    public var frame: IBRect?
    public var autoresizingMask: [String: String]?
    public var safeArea: IBLayoutGuide?
    public var colors: [String: IBColor]
    public var fontDescription: [String: String]?
    /// Label text: the `text` attribute or the `<string key="text">` element (labels only).
    public var text: String?
    /// Image view image: the `image`/`catalog` attributes or `<imageReference key="image">` (image views only).
    public var image: IBImageReference?
    public var subviews: [IBView]
    public var constraints: [IBConstraint]
    /// Keys of `<nil key="…"/>` children (explicitly unset properties).
    public var nilKeys: Set<String>
    public var line: Int
    public var rawPath: [Int]
}

public struct IBViewController: Equatable, Sendable {
    public var id: String
    public var attributes: [String: String]
    public var view: IBView
    public var rawPath: [Int]
}

public struct IBPlaceholder: Equatable, Sendable {
    public var id: String
    public var attributes: [String: String]
    public var rawPath: [Int]
}

public struct IBScene: Equatable, Sendable {
    public var sceneID: String
    public var viewController: IBViewController
    public var placeholders: [IBPlaceholder]
    public var rawPath: [Int]
}

public enum IBResource: Equatable, Sendable {
    case systemColor(String, IBColor)
    case namedColor(String, IBColor?)
    case image(String, width: String?, height: String?, catalog: String?)
}

public struct IBDocument: Equatable, Sendable {
    public var toolsVersion: String
    public var targetRuntime: String
    public var useAutolayout: Bool
    public var useSafeAreas: Bool
    public var useTraitCollections: Bool
    public var initialViewController: String
    public var scenes: [IBScene]
    public var resources: [IBResource]
    /// Raw path of each entry of `resources` (parallel array).
    public var resourcePaths: [[Int]]
    /// Raw `<document>` attributes, kept for the lowering rules.
    public var attributes: [String: String]
    /// The whole document as a lossless raw tree.
    public var raw: IBRawElement

    /// The raw element at a `rawPath` (child indices from the root), if any.
    public func element(at path: [Int]) -> IBRawElement? {
        var e = raw
        for i in path {
            guard e.children.indices.contains(i) else { return nil }
            e = e.children[i]
        }
        return e
    }
}
