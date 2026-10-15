import Foundation
import XlessCore

/// `UILabel` (docs/research/nib-encoding.md, section 6 "UIView subclasses" and "UILabel"; corpus `label-*`).
///
/// Keys: the common `UIView` keys (`ViewRule.encode`), then `UIText`, [`UIAdjustsFontForContentSizeCategory`],
/// `UIFont`, `UITextColor`, `UIShadowOffset` = (0, -1), [`UINumberOfLines`], [`UIBaselineAdjustment`],
/// [`UIAdjustsFontSizeToFit`], [`UIMinimumFontSize`], [`UILineBreakMode`], `UITextAlignment`, [`UIEnabled`],
/// [`UIMinimumScaleFactor`], `UIDisableUpdateTextColorOnTraitCollectionChange`. The order of the optional keys is
/// pinned by `label-keys-combined`, which sets all of them at once.
enum LabelRule {
    /// Attributes proven for labels: Xcode's defaults (`label-plain`), each toggled (`label-opaque-default`,
    /// `label-userinteraction-default`, `label-hugging-*`, `label-contentmode-*`, `label-align-*`, `label-lines-*`,
    /// `label-linebreak-*`, `label-behavior-grid`, `label-autoshrink-grid`) and the spellings Xcode does not write
    /// (`label-attrs-explicit`).
    static let attributes = ViewRule.subviewAttributes.union([
        "horizontalCompressionResistancePriority", "verticalCompressionResistancePriority", "text", "textAlignment",
        "lineBreakMode", "numberOfLines", "baselineAdjustment", "adjustsFontSizeToFit", "minimumScaleFactor",
        "minimumFontSize", "enabled", "adjustsFontForContentSizeCategory",
    ])
    /// `label-color-*`, `label-color-forms` (text and background colors).
    static let colorKeys: Set<String> = ["backgroundColor", "textColor"]

    static let textAlignments: [String: Int] = ["left": 0, "center": 1, "right": 2, "justified": 3, "natural": 4]
    static let lineBreakModes: [String: Int] = [
        "wordWrap": 0, "characterWrap": 1, "clip": 2, "headTruncation": 3, "tailTruncation": 4, "middleTruncation": 5,
    ]
    static let baselineAdjustments: [String: Int] = ["alignBaselines": 0, "alignCenters": 1, "none": 2]

    /// Everything a label's keys need, checked before anything is encoded.
    struct Plan {
        var text: String?
        var font: FontEncoding
        var adjustsForContentSize: Bool
        /// nil for `<nil key="textColor"/>` and for no text color at all (both are labelColor).
        var textColor: IBColor?
        /// `UIDisableUpdateTextColorOnTraitCollectionChange`: NO only for `<nil key="textColor"/>`.
        var disableTextColorUpdate: Bool
        var lines: Int
        var baseline: Int
        var autoshrink: (minimumFontSize: Double, scaleFactor: Float)?
        var lineBreak: Int
        var alignment: Int
        var enabled: Bool
    }

    static func checkSupported(_ v: IBView, lowering l: ViewNibLowering) throws -> Plan {
        try ViewRule.checkCommon(v, attributes: attributes, colorKeys: colorKeys, isRoot: false, lowering: l,
                                 nilKeys: ["textColor", "highlightedColor"], allowsFont: true)
        if let s = v.subviews.first { throw LoweringError.unsupported("subview inside a <label>", line: s.line) }
        let a = v.attributes, line = v.line
        let raw = l.doc.element(at: v.rawPath)
        if let s = raw?.children.first(where: { $0.name == "string" }) {
            try LoweringError.checkAttributes(s.attributes, known: ["key"], element: "string", line: s.line)
        }
        // Xcode always writes `<nil key="highlightedColor"/>`; without it ibtool encodes a highlighted color.
        guard v.nilKeys.contains("highlightedColor") else {
            throw LoweringError.unsupported("<label> without <nil key=\"highlightedColor\"/> (Xcode always writes it)", line: line)
        }
        if v.nilKeys.contains("textColor"), v.colors["textColor"] != nil {
            throw LoweringError.unsupported("<label> with both <nil key=\"textColor\"/> and a text color", line: line)
        }
        guard let fontAttributes = v.fontDescription else {
            throw LoweringError.unsupported("<label> without <fontDescription> (Xcode always writes it)", line: line)
        }
        let fontLine = raw?.children.first { $0.name == "fontDescription" }?.line
        let font = try FontRule.encoding(fontAttributes, line: fontLine)

        func lookup(_ key: String, _ table: [String: Int], default d: Int?) throws -> Int {
            guard let s = a[key] else {
                if let d { return d }
                throw LoweringError.unsupported("<label> without \(key) (Xcode always writes it)", line: line)
            }
            guard let value = table[s] else { throw LoweringError.unsupported("\(key)=\"\(s)\" on <label>", line: line) }
            return value
        }
        // An absent textAlignment is left (`label-align-omitted`); lineBreakMode and baselineAdjustment are always
        // written by Xcode, and without them ibtool uses other defaults (UIBaselineAdjustment 1).
        let alignment = try lookup("textAlignment", textAlignments, default: 0)
        let lineBreak = try lookup("lineBreakMode", lineBreakModes, default: nil)
        let baseline = try lookup("baselineAdjustment", baselineAdjustments, default: nil)

        var lines = 1
        if let s = a["numberOfLines"] {
            guard let n = Int(s), String(n) == s, (0...32767).contains(n) else {
                throw LoweringError.unsupported("numberOfLines=\"\(s)\" (supported: whole numbers 0–32767)", line: line)
            }
            lines = n
        }
        let enabled = try LoweringError.bool(a, "enabled", line: line) ?? true

        var adjustsForContentSize = false
        switch a["adjustsFontForContentSizeCategory"] {
        case nil: break
        case "YES":
            // Xcode warns unless the font is a text style; only that form is proven (`label-behavior-grid`).
            guard case .textStyle = font.kind else {
                throw LoweringError.unsupported("adjustsFontForContentSizeCategory=\"YES\" without a text style font", line: line)
            }
            adjustsForContentSize = true
        case let other?:
            throw LoweringError.unsupported("adjustsFontForContentSizeCategory=\"\(other)\" on <label>", line: line)
        }

        return Plan(text: try text(v), font: font, adjustsForContentSize: adjustsForContentSize,
                    textColor: v.colors["textColor"], disableTextColorUpdate: !v.nilKeys.contains("textColor"),
                    lines: lines, baseline: baseline, autoshrink: try autoshrink(a, font: font, line: line),
                    lineBreak: lineBreak, alignment: alignment, enabled: enabled)
    }

    /// Autoshrink, in the three forms Xcode writes (`label-autoshrink-grid`, `label-react-native-template`):
    /// - "Fixed Font Size": `adjustsFontSizeToFit="NO"` → no keys;
    /// - "Minimum Font Scale": `minimumScaleFactor="f"` without `adjustsFontSizeToFit` → `UIMinimumScaleFactor` = float f,
    ///   `UIMinimumFontSize` = pointSize × f rounded to the nearest quarter point (halves up), omitted when 0;
    /// - "Minimum Font Size": `minimumFontSize="m"` → `UIMinimumFontSize` = float m, `UIMinimumScaleFactor` =
    ///   float(m / pointSize).
    /// Both set `UIAdjustsFontSizeToFit` = YES. Text-style fonts (their size comes from elsewhere), `m` > pointSize
    /// (ibtool warns) and every other combination are refused.
    static func autoshrink(_ a: [String: String], font: FontEncoding, line: Int?) throws -> (minimumFontSize: Double, scaleFactor: Float)? {
        let adjusts = a["adjustsFontSizeToFit"], factor = a["minimumScaleFactor"], minimum = a["minimumFontSize"]
        switch (adjusts, factor, minimum) {
        case ("NO", nil, nil):
            return nil
        case (nil, let f?, nil):
            guard let p = font.scalableSize else { throw LoweringError.unsupported("minimumScaleFactor with a text style font", line: line) }
            guard let s = try LoweringError.number(a, "minimumScaleFactor", element: "label", line: line), s > 0, s < 1 else {
                throw LoweringError.unsupported("minimumScaleFactor=\"\(f)\" (supported: 0 < factor < 1)", line: line)
            }
            return ((p * s * 4).rounded(.toNearestOrAwayFromZero) / 4, Float(s))
        case (nil, nil, let m?):
            guard let p = font.scalableSize else { throw LoweringError.unsupported("minimumFontSize with a text style font", line: line) }
            guard let size = try LoweringError.number(a, "minimumFontSize", element: "label", line: line), size > 0, size <= p else {
                throw LoweringError.unsupported("minimumFontSize=\"\(m)\" (supported: 0 < size ≤ the font size \(p))", line: line)
            }
            return (size, Float(size / p))
        default:
            let given = [("adjustsFontSizeToFit", adjusts), ("minimumScaleFactor", factor), ("minimumFontSize", minimum)]
                .compactMap { k, v in v.map { "\(k)=\"\($0)\"" } }
            throw LoweringError.unsupported("autoshrink \(given.isEmpty ? "attributes missing" : given.joined(separator: " ")) on <label> (supported: adjustsFontSizeToFit=\"NO\", or minimumScaleFactor or minimumFontSize alone)", line: line)
        }
    }

    /// The text as ibtool stores it (`label-text-forms`): every leading U+FEFF is dropped (later ones are kept).
    /// Everything else is kept as is: no Unicode normalization (NFC and NFD stay different), U+2028, U+2029, U+0085,
    /// tabs, newlines, leading and trailing spaces. A carriage return is refused by `text(_:)`.
    static func normalizedText(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.drop { $0 == "\u{FEFF}" }))
    }

    /// The label's text. XML parsing turns literal CR LF and CR into LF; a CR that survives comes from a character
    /// reference (`&#13;`), which ibtool sometimes turns into LF and sometimes keeps (`label-text-carriage-return`).
    static func text(_ v: IBView) throws -> String? {
        guard let t = v.text else { return nil }
        if t.unicodeScalars.contains("\r") {
            throw LoweringError.unsupported("label text with a carriage return (&#13;) (ibtool keeps or converts it depending on the text)", line: v.line)
        }
        return normalizedText(t)
    }

    static func encode(_ v: IBView, plan: Plan, into ref: ObjectRef, parts: ViewRule.Parts, lowering l: ViewNibLowering) throws {
        try ViewRule.encode(v, into: ref, parts: parts, lowering: l)
        let b = l.b
        if let text = plan.text { b.set(ref, "UIText", b.string(text)) } else { b.set(ref, "UIText", .null) }
        if plan.adjustsForContentSize { b.set(ref, "UIAdjustsFontForContentSizeCategory", .bool(true)) }
        b.set(ref, "UIFont", try plan.font.encode(b))
        // No text color, or `<nil key="textColor"/>`, is labelColor (`label-plain`, `label-react-native-template`).
        let color = try plan.textColor.map { try ColorRule.encoding($0, doc: l.doc) } ?? ColorRule.system("labelColor", line: v.line)
        b.set(ref, "UITextColor", color.encode(b))
        b.set(ref, "UIShadowOffset", ArchiveBuilder.doubles([0, -1]))
        if plan.lines != 1 { b.set(ref, "UINumberOfLines", try ArchiveBuilder.int(plan.lines)) }
        if plan.baseline != 0 { b.set(ref, "UIBaselineAdjustment", try ArchiveBuilder.int(plan.baseline)) }
        if let shrink = plan.autoshrink {
            b.set(ref, "UIAdjustsFontSizeToFit", .bool(true))
            if shrink.minimumFontSize != 0 { b.set(ref, "UIMinimumFontSize", .float(Float(shrink.minimumFontSize))) }
        }
        if plan.lineBreak != 4 { b.set(ref, "UILineBreakMode", try ArchiveBuilder.int(plan.lineBreak)) }
        b.set(ref, "UITextAlignment", try ArchiveBuilder.int(plan.alignment))
        if !plan.enabled { b.set(ref, "UIEnabled", .bool(false)) }
        if let shrink = plan.autoshrink { b.set(ref, "UIMinimumScaleFactor", .float(shrink.scaleFactor)) }
        b.set(ref, "UIDisableUpdateTextColorOnTraitCollectionChange", .bool(plan.disableTextColorUpdate))
    }
}
