import Foundation
import XlessCore

/// `UIView`: the root view and plain `<view>` subviews (docs/research/nib-encoding.md, section 6 "UIView (root view)"
/// and "UIView subclasses"). Proving cases: `core-*`, `device-*`, `color-system-table` (plain subviews).
///
/// Keys, in order: `UIBounds`, `UICenter`, [`UISubviews`], [`UIBackgroundColor`], `UIDeepDrawRect`, [`UIOpaque`],
/// [`UIUserInteractionDisabled`], `UIAutoresizeSubviews`, [`UIAutoresizingMask`], [`UIContentMode`], [`UIClipsToBounds`],
/// [`UITintColor`], [`UIViewDoesNotTranslateAutoresizingMaskIntoConstraints`], [`UIViewAutolayoutConstraints`],
/// [`UIViewContentHuggingPriority`], [`UIViewContentCompressionResistancePriority`], [`UIViewLayoutGuides`],
/// [`UIViewInsetsLayoutMarginsFromSafeArea`, root view only], `UIViewSemanticContentAttribute`,
/// `UIViewLargeContentStoredProperties`, then the class-specific keys (`ImageViewRule`, `LabelRule`).
enum ViewRule {
    /// Attributes of plain `<view>` subviews, each proven by a golden: `view-opaque-no`, `view-userinteraction-no`,
    /// `view-clips`, `view-contentmode-*`, `view-hugging-*`, and the spellings Xcode does not write
    /// (`opaque="YES"`, `clipsSubviews="NO"`, `userInteractionEnabled="YES"`, `fixedFrame="NO"`,
    /// `translatesAutoresizingMaskIntoConstraints` YES or absent) by `view-attrs-explicit`. `userLabel` (Interface
    /// Builder's outline name) changes nothing on any view kind (`view-userlabel-grid`).
    static let subviewAttributes: Set<String> = [
        "id", "contentMode", "fixedFrame", "translatesAutoresizingMaskIntoConstraints", "opaque",
        "userInteractionEnabled", "clipsSubviews", "horizontalHuggingPriority", "verticalHuggingPriority", "userLabel",
    ]

    /// Subview attributes that ibtool also reads in expo-splash-screen's lowercase spelling, `true`/`false`, exactly
    /// as YES/NO (`bool-lowercase-grid`: each value on a plain view, an image view and a label, all constrained).
    static let lowercaseBooleans: Set<String> = ["clipsSubviews", "userInteractionEnabled", "translatesAutoresizingMaskIntoConstraints"]

    /// A boolean attribute of `v`: YES/NO, or for subviews also `true`/`false` where proven (`lowercaseBooleans`).
    /// The root view (the one with a `key`) keeps the strict YES/NO.
    static func flag(_ v: IBView, _ key: String) throws -> Bool? {
        try LoweringError.bool(v.attributes, key, line: v.line, lowercase: v.key == nil && lowercaseBooleans.contains(key))
    }

    /// What a view's keys refer to besides its own attributes.
    struct Parts {
        var size: (width: Double, height: Double)
        var center: (x: Double, y: Double)
        var subviews: [ObjectRef] = []
        var constraints: [ObjectRef] = []
        var layoutGuides: [ObjectRef] = []
        /// The view is the first or second item of a constraint (the owning view counts as the implicit first item).
        var constrained = false
    }

    /// Writes the common `UIView` keys of `v` into `ref`.
    static func encode(_ v: IBView, into ref: ObjectRef, parts: Parts, lowering l: ViewNibLowering) throws {
        let b = l.b
        b.set(ref, "UIBounds", ArchiveBuilder.doubles([0, 0, parts.size.width, parts.size.height]))
        b.set(ref, "UICenter", ArchiveBuilder.doubles([parts.center.x, parts.center.y]))
        if !parts.subviews.isEmpty { b.set(ref, "UISubviews", b.array(parts.subviews, mutable: true)) }
        if let bg = v.colors["backgroundColor"] { b.set(ref, "UIBackgroundColor", try ColorRule.encode(bg, lowering: l)) }
        b.set(ref, "UIDeepDrawRect", .bool(true))
        if try flag(v, "opaque") != false { b.set(ref, "UIOpaque", .bool(true)) }
        if try flag(v, "userInteractionEnabled") == false { b.set(ref, "UIUserInteractionDisabled", .bool(true)) }
        b.set(ref, "UIAutoresizeSubviews", .bool(true))
        let mask = try autoresizingMask(v, lowering: l)
        if mask != 0 { b.set(ref, "UIAutoresizingMask", try ArchiveBuilder.int(mask)) }
        let mode = try contentMode(v)
        if mode != 0 { b.set(ref, "UIContentMode", try ArchiveBuilder.int(mode)) }
        if try flag(v, "clipsSubviews") == true { b.set(ref, "UIClipsToBounds", .bool(true)) }
        // The system `tintColor` as a tint is the default: ibtool writes no key for it (`image-tint-default`,
        // `color-default-forms`; as a background or text color it is encoded like any system color).
        if let tint = v.colors["tintColor"] {
            let encoding = try ColorRule.encoding(tint, lowering: l, encoded: tint.value != .system("tintColor"))
            if encoding.name != .system("tintColor") { b.set(ref, "UITintColor", encoding.encode(b)) }
        }
        // Only a view that takes part in a constraint gets the key; `fixedFrame="YES"` or no constraint means
        // autoresizing (`image-catalog-*`, `image-with-constraints`, `view-attrs-explicit`, `view-translates-unconstrained`).
        if parts.constrained,
           try flag(v, "translatesAutoresizingMaskIntoConstraints") == false,
           try flag(v, "fixedFrame") != true {
            b.set(ref, "UIViewDoesNotTranslateAutoresizingMaskIntoConstraints", .bool(true))
        }
        if !parts.constraints.isEmpty { b.set(ref, "UIViewAutolayoutConstraints", b.array(parts.constraints, mutable: true)) }
        if let hugging = try hugging(v) { b.set(ref, "UIViewContentHuggingPriority", b.string(hugging)) }
        if let resistance = try compressionResistance(v) { b.set(ref, "UIViewContentCompressionResistancePriority", b.string(resistance)) }
        if !parts.layoutGuides.isEmpty { b.set(ref, "UIViewLayoutGuides", b.array(parts.layoutGuides, mutable: true)) }
        // Root view only (`rootAttributes`): NO gives int8 0 after the layout guides, in safe-area and legacy mode;
        // YES gives nothing (`root-insets-no`, `root-insets-no-safearea`, `root-insets-no-legacy`, `root-insets-yes`).
        if try flag(v, "insetsLayoutMarginsFromSafeArea") == false { b.set(ref, "UIViewInsetsLayoutMarginsFromSafeArea", .int8(0)) }
        b.set(ref, "UIViewSemanticContentAttribute", .int8(0))
        b.set(ref, "UIViewLargeContentStoredProperties", .null)
    }

    /// The root view: what every corpus root has (`key`, `id`, `contentMode="scaleToFill"`), plus the three attributes
    /// of Expo's template (YES/NO only): `userInteractionEnabled` (`root-userinteraction-no`, `-yes`: the subviews'
    /// `UIUserInteractionDisabled`), `insetsLayoutMarginsFromSafeArea` (`root-insets-*`) and `userLabel` (no effect,
    /// `view-userlabel-grid`).
    static let rootAttributes: Set<String> = ["key", "id", "contentMode", "userInteractionEnabled", "insetsLayoutMarginsFromSafeArea", "userLabel"]

    /// Checks that a `<view>` (root or plain subview) uses only what these rules encode.
    static func checkSupported(_ v: IBView, isRoot: Bool, lowering l: ViewNibLowering) throws {
        if isRoot {
            if let bad = v.attributes.keys.sorted().first(where: { !rootAttributes.contains($0) }) {
                throw LoweringError.unsupported("attribute \(bad)=\"\(v.attributes[bad]!)\" on the root <view>", line: v.line)
            }
            guard v.attributes["contentMode"] == "scaleToFill" else {
                throw LoweringError.unsupported("contentMode=\"\(v.attributes["contentMode"] ?? "")\" on the root <view> (verified: scaleToFill)", line: v.line)
            }
        }
        try checkCommon(v, attributes: isRoot ? rootAttributes : subviewAttributes, colorKeys: ["backgroundColor"], isRoot: isRoot, lowering: l)
    }

    /// The checks shared by every view kind: `attributes` and `<color key>`s are the ones proven for the kind.
    /// `nilKeys` are the `<nil key>` children the kind may have; `allowsFont` admits a `<fontDescription>` (labels).
    static func checkCommon(_ v: IBView, attributes: Set<String>, colorKeys: Set<String>, isRoot: Bool, lowering l: ViewNibLowering,
                            nilKeys: Set<String> = [], allowsFont: Bool = false) throws {
        try LoweringError.checkAttributes(v.attributes, known: attributes, element: v.kind.rawValue, line: v.line)
        _ = try contentMode(v)
        for key in ["opaque", "userInteractionEnabled", "clipsSubviews", "fixedFrame", "translatesAutoresizingMaskIntoConstraints",
                    "insetsLayoutMarginsFromSafeArea"] {
            _ = try flag(v, key)
        }
        _ = try AccessibilityRule.value(v)
        _ = try hugging(v)
        _ = try compressionResistance(v)
        if let raw = l.doc.element(at: v.rawPath), let rect = raw.children.first(where: { $0.name == "rect" && $0.attributes["key"] != "frame" }) {
            throw LoweringError.unsupported("<rect key=\"\(rect.attributes["key"] ?? "")\">", line: rect.line)
        }
        if let key = v.colors.keys.sorted().first(where: { !colorKeys.contains($0) }) {
            throw LoweringError.unsupported("color key \"\(key)\" on <\(v.kind.rawValue)>", line: v.colors[key].flatMap { l.doc.element(at: $0.rawPath)?.line })
        }
        if let key = v.nilKeys.sorted().first(where: { !nilKeys.contains($0) }) {
            throw LoweringError.unsupported("<nil key=\"\(key)\"> on <\(v.kind.rawValue)>", line: v.line)
        }
        if v.fontDescription != nil, !allowsFont { throw LoweringError.unsupported("<fontDescription> on <\(v.kind.rawValue)>", line: v.line) }
        if v.safeArea != nil, !isRoot { throw LoweringError.unsupported("safe area guide on a subview", line: v.line) }
        if let raw = l.doc.element(at: v.rawPath),
           let guide = raw.children.first(where: { $0.name == "viewLayoutGuide" && $0.attributes["key"] != "safeArea" }) {
            throw LoweringError.unsupported("<viewLayoutGuide key=\"\(guide.attributes["key"] ?? "")\">", line: guide.line)
        }
    }

    // MARK: Attribute values

    /// `UIContentMode` values (Xcode spells top-left `TopLeft`).
    static let contentModes: [String: Int] = [
        "scaleToFill": 0, "scaleAspectFit": 1, "scaleAspectFill": 2, "redraw": 3, "center": 4, "top": 5, "bottom": 6,
        "left": 7, "right": 8, "TopLeft": 9, "topRight": 10, "bottomLeft": 11, "bottomRight": 12,
    ]
    /// The content modes proven per element kind: plain views by `view-contentmode-grid` (and `-center`, `-redraw`),
    /// image views by `image-catalog-*` and `image-mode-*`, labels by `label-contentmode-grid`. The root view is
    /// checked separately.
    static let provenContentModes: [IBView.Kind: Set<String>] = [
        .view: Set(contentModes.keys), .imageView: Set(contentModes.keys), .label: Set(contentModes.keys),
    ]

    /// The `UIContentMode` value. Xcode always writes `contentMode`; ibtool maps an unknown string to scaleToFill
    /// (`image-mode-unknown`), but the compiler refuses it rather than generalise from two samples (`bogusMode`, `topLeft`).
    static func contentMode(_ v: IBView) throws -> Int {
        guard let s = v.attributes["contentMode"] else {
            throw LoweringError.unsupported("<\(v.kind.rawValue)> without contentMode (Xcode always writes it)", line: v.line)
        }
        guard let mode = contentModes[s], provenContentModes[v.kind, default: []].contains(s) else {
            throw LoweringError.unsupported("contentMode=\"\(s)\" on <\(v.kind.rawValue)>", line: v.line)
        }
        return mode
    }

    static let autoresizingFlags: [String: Int] = [
        "flexibleMinX": 1, "widthSizable": 2, "flexibleMaxX": 4, "flexibleMinY": 8, "heightSizable": 16, "flexibleMaxY": 32,
    ]

    /// OR of the flags; no `<autoresizingMask>` element means 36 (`core-autoresizing-*`).
    static func autoresizingMask(_ v: IBView, lowering l: ViewNibLowering) throws -> Int {
        guard let attrs = v.autoresizingMask else { return 36 }
        let line = l.doc.element(at: v.rawPath)?.children.first { $0.name == "autoresizingMask" }?.line
        try LoweringError.checkAttributes(attrs, known: Set(autoresizingFlags.keys).union(["key"]), element: "autoresizingMask", line: line)
        var mask = 0
        for (flag, bit) in autoresizingFlags {
            switch attrs[flag] {
            case nil, "NO": break
            case "YES": mask |= bit
            case let other?: throw LoweringError.unsupported("autoresizingMask \(flag)=\"\(other)\"", line: line)
            }
        }
        return mask
    }

    /// `"{h, v}"`, omitted when both are 250 (`view-hugging-250`; explicit or absent). An absent axis counts as 250
    /// (`"{251, 250}"` for `horizontalHuggingPriority="251"` alone). Mixed axes, single axes, explicit 250/250 and the
    /// extremes 1 and 1000 are proven for plain and image views by `view-hugging-grid` and `image-hugging-grid`.
    static func hugging(_ v: IBView) throws -> String? {
        try priorityPair(v, "horizontalHuggingPriority", "verticalHuggingPriority", default: 250)
    }

    /// `"{h, v}"` from `horizontalCompressionResistancePriority`/`verticalCompressionResistancePriority`, omitted when
    /// both are the default 750; an absent axis counts as 750 (`label-hugging-grid`, `label-keys-combined`). Only
    /// labels accept these attributes.
    static func compressionResistance(_ v: IBView) throws -> String? {
        try priorityPair(v, "horizontalCompressionResistancePriority", "verticalCompressionResistancePriority", default: 750)
    }

    private static func priorityPair(_ v: IBView, _ hKey: String, _ vKey: String, default d: Int) throws -> String? {
        func priority(_ key: String) throws -> Int {
            guard let s = v.attributes[key] else { return d }
            guard let p = Int(s), String(p) == s, (1...1000).contains(p) else {
                throw LoweringError.unsupported("\(key)=\"\(s)\" (supported: whole numbers 1–1000)", line: v.line)
            }
            return p
        }
        let (h, vv) = (try priority(hKey), try priority(vKey))
        return h == d && vv == d ? nil : "{\(h), \(vv)}"
    }
}
