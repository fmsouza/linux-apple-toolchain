import Foundation
import XlessCore

/// `UIRuntimeAccessibilityConfiguration`: a view's `<accessibility key="accessibilityConfiguration">` with
/// `<accessibilityTraits key="traits" …/>` (docs/research/nib-encoding.md, section 6 "UIRuntimeAccessibilityConfiguration";
/// Expo's `SplashScreen.storyboard` has `image="YES" notEnabled="YES"` on its image view).
///
/// Keys: `UIAccessibileObject` (sic) = @the view, `UIAccessibilityTraits` = @NSNumber `NS.intval` = the OR of the traits
/// set to YES (0 for none: an element always gives a configuration, `acc-traits-grid`). The NSNumber is shared by value
/// with other numbers, fonts' included (`acc-number-sharing`). The root object's `UINibAccessibilityConfigurationsKey`
/// is then an `NSArray` of the configurations, in objects-list order of their views (`acc-kinds-order`: root first, then
/// the subviews breadth-first), instead of the shared empty array. Every view kind and the root take one
/// (`acc-kinds-order`).
enum AccessibilityRule {
    /// The trait attributes ibtool encodes, with their `UIAccessibilityTraits` bits (`acc-traits-grid`, one image view
    /// per trait). ibtool ignores other attribute names (`tabBar`, `frequentAdds` gave 0 in a scratch run); they are refused.
    static let traits: [String: Int] = [
        "button": 1, "link": 2, "image": 4, "selected": 8, "playsSound": 16, "keyboardKey": 32, "staticText": 64,
        "summaryElement": 128, "notEnabled": 256, "updatesFrequently": 512, "searchField": 1024, "startsMediaSession": 2048,
        "adjustable": 4096, "allowsDirectInteraction": 8192, "causesPageTurn": 16384, "header": 65536,
    ]

    /// The traits value of `v`'s accessibility element, or nil without one. Refuses anything but the traits element
    /// with YES/NO trait attributes.
    static func value(_ v: IBView) throws -> Int? {
        guard let a = v.accessibility else { return nil }
        try LoweringError.checkAttributes(a.attributes, known: ["key"], element: "accessibility", line: a.line)
        guard let t = a.traits else {
            throw LoweringError.unsupported("<accessibility> without <accessibilityTraits key=\"traits\">", line: a.line)
        }
        try LoweringError.checkAttributes(t, known: Set(traits.keys).union(["key"]), element: "accessibilityTraits", line: a.line)
        var value = 0
        for (name, bit) in traits {
            if try LoweringError.bool(t, name, line: a.line) == true { value |= bit }
        }
        return value
    }

    /// The configurations of `views` (view object, traits), in the given (objects-list) order. Call after every view
    /// is lowered: the traits number is shared with an equal number encoded before it (a font's).
    static func encode(_ views: [(ref: ObjectRef, traits: Int)], into b: ArchiveBuilder) throws -> [ObjectRef] {
        try views.map { v in
            let c = b.object("UIRuntimeAccessibilityConfiguration")
            b.set(c, "UIAccessibileObject", v.ref)
            b.set(c, "UIAccessibilityTraits", try b.number(Double(v.traits), integer: true))
            return c
        }
    }
}
