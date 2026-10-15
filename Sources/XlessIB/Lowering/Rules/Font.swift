import Foundation
import XlessCore

/// `UIFont` and `UIFontDescriptor`: a label's `<fontDescription>` (docs/research/nib-encoding.md, section 6 "UIFont and
/// UIFontDescriptor"). Three forms, each proven by goldens:
///
/// - System font (`type="system"` with an optional `weight`, `type="boldSystem"`, `type="italicSystem"`):
///   `UIFontName`, `UIFontDescriptor`, `UIFontPointSize`, `UIFontTextStyleForScaling` = nil,
///   `UIFontPointSizeForScaling` = 0, `UIFontMaximumPointSizeAfterScaling` = 0, `UIFontTraits`, `UISystemFont` = YES,
///   `NSName` (the `UIFontName` string), `NSSize`. Names, usages and traits do not depend on the size
///   (`label-font-grid`: every weight, bold and italic at 0.5 … 100; `label-weight-*`, `label-system-*`, `label-italic`).
/// - Text style (`style="UICTFontTextStyle…"`): no descriptor; `UIIBTextStyle` after `UIFontName`, point size 0 and
///   `NSSize` from ibtool's table (`label-textstyle-*`, `label-textstyle-grid`).
/// - Custom font (`name="PostScriptName"`): only the form ibtool gives a font it cannot resolve (`UIFontDescriptorOptions`
///   = 0, traits 0, no scaling keys; `label-custom-font-missing`, `label-custom-font-grid`). A name of a font shipped
///   with macOS or the iOS simulator runtime is refused (`KnownFonts`, open question 3).
///
/// Equal fonts are one object, and so are equal descriptors, dictionaries and numbers (`label-font-grid`).
struct FontEncoding: Hashable, CustomStringConvertible {
    enum Kind: Hashable { case system(SystemFont), textStyle(TextStyle), custom(String) }
    var kind: Kind
    /// `pointSize` (0 for text styles).
    var pointSize: Double

    var description: String { "\(kind)|\(pointSize)" }

    /// The size autoshrink scales from; nil for text styles, whose size ibtool takes from elsewhere (refused).
    var scalableSize: Double? {
        if case .textStyle = kind { return nil }
        return pointSize
    }

    func encode(_ b: ArchiveBuilder) throws -> ObjectRef {
        try b.unique("UIFont|\(self)") {
            let f = b.object("UIFont", fallback: "NSFont")
            switch kind {
            case .system(let s):
                let name = b.string(s.name)
                b.set(f, "UIFontName", name)
                b.set(f, "UIFontDescriptor", try descriptor(b, entries: s.descriptorEntries(b, pointSize: pointSize), options: 2147517444,
                                                            mutable: s.mutableAttributes, identity: "system|\(s)|\(pointSize)"))
                b.set(f, "UIFontPointSize", .double(pointSize))
                Self.setScaling(f, b)
                b.set(f, "UIFontTraits", try ArchiveBuilder.int(s.traits))
                b.set(f, "UISystemFont", .bool(true))
                b.set(f, "NSName", name)
                b.set(f, "NSSize", .double(pointSize))
            case .textStyle(let t):
                let name = b.string(t.fontName)
                b.set(f, "UIFontName", name)
                b.set(f, "UIIBTextStyle", b.string(t.rawValue))
                b.set(f, "UIFontPointSize", .double(0))
                Self.setScaling(f, b)
                b.set(f, "UIFontTraits", try ArchiveBuilder.int(t.traits))
                b.set(f, "UISystemFont", .bool(true))
                b.set(f, "NSName", name)
                b.set(f, "NSSize", .double(t.size))
            case .custom(let n):
                let name = b.string(n)
                b.set(f, "UIFontName", name)
                let entries = [(b.string("NSFontNameAttribute"), name), (b.string("NSFontSizeAttribute"), try b.number(pointSize))]
                b.set(f, "UIFontDescriptor", try descriptor(b, entries: entries, options: 0, mutable: false, identity: "custom|\(n)|\(pointSize)"))
                b.set(f, "UIFontPointSize", .double(pointSize))
                b.set(f, "UIFontTraits", .int8(0))
                b.set(f, "UISystemFont", .bool(false))
                b.set(f, "NSName", name)
                b.set(f, "NSSize", .double(pointSize))
            }
            return f
        }
    }

    private static func setScaling(_ f: ObjectRef, _ b: ArchiveBuilder) {
        b.set(f, "UIFontTextStyleForScaling", .null)
        b.set(f, "UIFontPointSizeForScaling", .double(0))
        b.set(f, "UIFontMaximumPointSizeAfterScaling", .double(0))
    }

    /// `UIFontDescriptor`: `UIFontDescriptorAttributes` = the dictionary (entries in ascending key order, as observed;
    /// open question 8), `UIFontDescriptorOptions`.
    private func descriptor(_ b: ArchiveBuilder, entries: [(ObjectRef, ObjectRef)], options: Int, mutable: Bool, identity: String) throws -> ObjectRef {
        try b.unique("UIFontDescriptor|" + identity) {
            let d = b.object("UIFontDescriptor")
            b.set(d, "UIFontDescriptorAttributes", b.dictionary(entries.map { (key: $0.0, value: $0.1) }, identity: identity, mutable: mutable))
            b.set(d, "UIFontDescriptorOptions", try ArchiveBuilder.int(options))
            return d
        }
    }
}

/// A system font: `type="system"` with a weight, `type="boldSystem"` (the same font as weight bold) or
/// `type="italicSystem"`.
enum SystemFont: String, Hashable {
    case regular, ultraLight, thin, light, medium, semibold, bold, heavy, black, italic

    var name: String {
        switch self {
        case .regular: ".SFUI-Regular"
        case .ultraLight: ".SFUI-Ultralight"
        case .thin: ".SFUI-Thin"
        case .light: ".SFUI-Light"
        case .medium: ".SFUI-Medium"
        case .semibold: ".SFUI-Semibold"
        case .bold: ".SFUI-Bold"
        case .heavy: ".SFUI-Heavy"
        case .black: ".SFUI-Black"
        case .italic: ".SFUI-RegularItalic"
        }
    }

    var traits: Int {
        switch self {
        case .regular, .medium: 0
        case .ultraLight: 16
        case .thin: 4
        case .light: 8
        case .semibold, .bold, .heavy, .black: 2
        case .italic: 1
        }
    }

    var usage: String {
        switch self {
        case .regular: "CTFontRegularUsage"
        case .ultraLight: "CTFontUltraLightUsage"
        case .thin: "CTFontThinUsage"
        case .light: "CTFontLightUsage"
        case .medium: "CTFontMediumUsage"
        case .semibold: "CTFontDemiUsage"
        case .bold: "CTFontEmphasizedUsage"
        case .heavy: "CTFontHeavyUsage"
        case .black: "CTFontBlackUsage"
        case .italic: "CTFontObliqueUsage"
        }
    }

    /// Only the bold font's attributes are an `NSMutableDictionary` (`label-weight-bold`, `label-system-*-bold`).
    var mutableAttributes: Bool { self == .bold }

    /// The descriptor attributes, in key order: regular weights {Usage, Size}; bold {Usage: CTFontEmphasizedUsage,
    /// UsageOverride: CTFontBoldUsage, Size}; italic {Traits: {SymbolicTrait: intval 1}, Usage: CTFontObliqueUsage, Size}.
    func descriptorEntries(_ b: ArchiveBuilder, pointSize: Double) throws -> [(ObjectRef, ObjectRef)] {
        var entries: [(ObjectRef, ObjectRef)] = []
        if self == .italic {
            let trait = b.dictionary([(key: b.string("NSCTFontSymbolicTrait"), value: try b.number(1, integer: true))],
                                     identity: "NSCTFontSymbolicTrait=1")
            entries.append((b.string("NSCTFontTraitsAttribute"), trait))
        }
        entries.append((b.string("NSCTFontUIUsageAttribute"), b.string(usage)))
        if self == .bold { entries.append((b.string("NSCTFontUIUsageOverrideAttribute"), b.string("CTFontBoldUsage"))) }
        entries.append((b.string("NSFontSizeAttribute"), try b.number(pointSize)))
        return entries
    }
}

/// The text styles Xcode offers (`label-textstyle-*`, `label-textstyle-grid`), with ibtool's font name, traits and size.
enum TextStyle: String, Hashable, CaseIterable {
    case title0 = "UICTFontTextStyleTitle0", title1 = "UICTFontTextStyleTitle1", title2 = "UICTFontTextStyleTitle2"
    case title3 = "UICTFontTextStyleTitle3", headline = "UICTFontTextStyleHeadline", subhead = "UICTFontTextStyleSubhead"
    case body = "UICTFontTextStyleBody", callout = "UICTFontTextStyleCallout", footnote = "UICTFontTextStyleFootnote"
    case caption1 = "UICTFontTextStyleCaption1", caption2 = "UICTFontTextStyleCaption2"

    var fontName: String { self == .headline ? ".SFUI-Semibold" : ".SFUI-Regular" }
    var traits: Int { self == .headline ? 2 : 0 }
    var size: Double {
        switch self {
        case .title0: 31
        case .title1: 25
        case .title2: 19
        case .title3: 17
        case .headline, .body: 14
        case .callout: 13
        case .subhead, .footnote: 12
        case .caption1, .caption2: 11
        }
    }
}

enum FontRule {
    static let attributes: Set<String> = ["key", "type", "weight", "pointSize", "style", "name", "family"]
    static let weights: [String: SystemFont] = [
        "regular": .regular, "ultraLight": .ultraLight, "thin": .thin, "light": .light, "medium": .medium,
        "semibold": .semibold, "bold": .bold, "heavy": .heavy, "black": .black,
    ]

    /// Lowers a `<fontDescription>`; everything outside the three proven forms is refused.
    static func encoding(_ a: [String: String], line: Int?) throws -> FontEncoding {
        try LoweringError.checkAttributes(a, known: attributes, element: "fontDescription", line: line)
        func only(_ keys: Set<String>) throws {
            if let bad = a.keys.sorted().first(where: { !keys.contains($0) }) {
                throw LoweringError.unsupported("attribute \(bad)=\"\(a[bad]!)\" on this <fontDescription> (\(ColorRule.describe(a)))", line: line)
            }
        }
        if let style = a["style"] {
            try only(["key", "style"])
            guard let s = TextStyle(rawValue: style) else {
                throw LoweringError.unsupported("text style \"\(style)\" (supported: \(TextStyle.allCases.map(\.rawValue).joined(separator: ", ")))", line: line)
            }
            return FontEncoding(kind: .textStyle(s), pointSize: 0)
        }
        if let name = a["name"] {
            try only(["key", "name", "family", "pointSize"])
            try checkCustom(name, line: line)
            return FontEncoding(kind: .custom(name), pointSize: try pointSize(a, line: line))
        }
        switch a["type"] {
        case "system":
            try only(["key", "type", "weight", "pointSize"])
            var font = SystemFont.regular
            if let w = a["weight"] {
                guard let f = weights[w] else { throw LoweringError.unsupported("font weight \"\(w)\"", line: line) }
                font = f
            }
            return FontEncoding(kind: .system(font), pointSize: try pointSize(a, line: line))
        case "boldSystem":
            try only(["key", "type", "pointSize"])
            return FontEncoding(kind: .system(.bold), pointSize: try pointSize(a, line: line))
        case "italicSystem":
            try only(["key", "type", "pointSize"])
            return FontEncoding(kind: .system(.italic), pointSize: try pointSize(a, line: line))
        case let t:
            throw LoweringError.unsupported("<fontDescription> \(t.map { "type=\"\($0)\"" } ?? "without type, style or name")", line: line)
        }
    }

    /// A positive, finite `pointSize` (Xcode's number spelling; 0.5 … 100 and fractions proven by `label-font-grid`).
    static func pointSize(_ a: [String: String], line: Int?) throws -> Double {
        guard let p = try LoweringError.number(a, "pointSize", element: "fontDescription", line: line) else {
            throw LoweringError.unsupported("<fontDescription> without pointSize", line: line)
        }
        guard p > 0 else { throw LoweringError.unsupported("font pointSize=\"\(a["pointSize"]!)\"", line: line) }
        return p
    }

    /// Hand-maintained (not generated, so `scripts/ib-corpus/known-fonts.sh` cannot drop it): lowercased custom font
    /// names for which ibtool produces no output to verify against (docs/research/nib-encoding.md, open question 3).
    /// - `stxihei`: ibtool hangs (killed after 60 s, twice, in the Task 8 fix-round probes); in no generated source.
    /// It was the only name that hung or errored among the 520 available names, 5 controls and 15 legacy aliases probed.
    static let unverifiable: Set<String> = ["stxihei"]

    /// ibtool resolves a custom font by its exact PostScript name; a font it resolves gets that font's traits and
    /// descriptor options (`label-custom-font` Helvetica-Bold, `label-custom-font-avenir`), which are not reproduced.
    /// Names of fonts shipped with macOS or the iOS simulator runtime are therefore refused (compared without case,
    /// with their family names too), as are names starting with "." (system UI fonts, which ibtool maps to another font).
    static func checkCustom(_ name: String, line: Int?) throws {
        guard !name.isEmpty else { throw LoweringError.unsupported("custom font with an empty name", line: line) }
        if unverifiable.contains(name.lowercased()) {
            throw LoweringError.openQuestion("font \"\(name)\" cannot be verified (ibtool does not compile it)", line: line,
                                             fix: "use the System font with a weight, a text style, or a font bundled with the app")
        }
        if name.hasPrefix(".") || KnownFonts.names.contains(name.lowercased()) {
            throw LoweringError.openQuestion("font \"\(name)\" ships with macOS or iOS; ibtool encodes such a font with its own traits, which are not reproduced",
                                             line: line, fix: "use the System font with a weight, a text style, or a font bundled with the app")
        }
    }
}
