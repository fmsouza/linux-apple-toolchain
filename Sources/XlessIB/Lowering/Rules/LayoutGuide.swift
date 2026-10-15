import Foundation

/// Layout guides (docs/research/nib-encoding.md, section 6 "UILayoutGuide (safe area)" and "Legacy layout guides").
enum LayoutGuideRule {
    /// Safe-area mode: the placeholder `UILayoutGuide` that is only listed in the objects list
    /// (`core-safearea`, `core-safearea-attr-only`, `core-safearea-guide-only`, `real-tauri-app`).
    static func safeAreaPlaceholder(_ b: ArchiveBuilder) -> ObjectRef {
        let g = b.object("UILayoutGuide")
        b.set(g, "UILayoutGuideOwningView", .null)
        b.set(g, "UILayoutGuideIdentifier", b.string(""))
        b.set(g, "UILayoutGuideOwningViewIsLocked", .bool(false))
        b.set(g, "UILayoutGuideShouldBeArchived", .bool(false))
        b.set(g, "UILayoutGuideAllowsNegativeDimensions", .bool(false))
        return g
    }

    /// The root view's safe-area guide, when a constraint refers to it (`cons-edges-safearea`, `real-logo-plus-label`):
    /// owned by the root view, with four system constraints tying it to the root's edges.
    static func ownedSafeAreaGuide(_ b: ArchiveBuilder, root: ObjectRef) -> ObjectRef {
        let g = b.object("UILayoutGuide")
        b.set(g, "UILayoutGuideOwningView", root)
        b.set(g, "UILayoutGuideIdentifier", b.string("UIViewSafeAreaLayoutGuide"))
        b.set(g, "UILayoutGuideOwningViewIsLocked", .bool(true))
        b.set(g, "UILayoutGuideShouldBeArchived", .bool(true))
        b.set(g, "UILayoutGuideAllowsNegativeDimensions", .bool(true))
        func system(_ first: ObjectRef, _ second: ObjectRef, _ attribute: LayoutAttribute, _ edge: String) -> ObjectRef {
            // Generated constraints never throw: attribute numbers are small and the priority is the default.
            try! GeneratedConstraint(first: first, firstAttribute: attribute, second: second, secondAttribute: attribute,
                                     archived: false, identifier: "UIViewSafeAreaLayoutGuide-\(edge)").encode(b)
        }
        b.set(g, "UILayoutGuideSystemConstraints", b.array([
            system(g, root, .top, "top"), system(g, root, .left, "left"),
            system(root, g, .bottom, "bottom"), system(root, g, .right, "right"),
        ]))
        return g
    }

    /// Legacy mode (no safe area): the top and bottom `_UILayoutGuide` subviews of the root view and the six
    /// constraints they add to the root's constraint array (`core-minimal`, `core-legacy-layoutguides`).
    struct Legacy { var top: ObjectRef; var bottom: ObjectRef; var rootConstraints: [ObjectRef] }

    static func legacyGuides(_ b: ArchiveBuilder, root: ObjectRef) throws -> Legacy {
        func guide(_ identifier: String, _ toRemove: (ObjectRef) throws -> [ObjectRef]) throws -> (ObjectRef, [ObjectRef]) {
            let g = b.object("_UILayoutGuide", fallback: "UIView")
            b.set(g, "UIDeepDrawRect", .bool(true))
            b.set(g, "UIOpaque", .bool(true))
            b.set(g, "UIHidden", .bool(true))
            b.set(g, "UIAutoresizeSubviews", .bool(true))
            b.set(g, "UIViewDoesNotTranslateAutoresizingMaskIntoConstraints", .bool(true))
            let support = try GeneratedConstraint(first: g, firstAttribute: .width, priority: 999)
                .encode(b, className: "_UILayoutSupportConstraint", fallback: "NSLayoutConstraint")
            b.set(g, "UIViewAutolayoutConstraints", b.array([support], mutable: true))
            b.set(g, "UIViewSemanticContentAttribute", .int8(0))
            b.set(g, "UIViewLargeContentStoredProperties", .null)
            b.set(g, "_UILayoutGuideIdentifier", b.string(identifier))
            let constraints = try toRemove(g)
            b.set(g, "_UILayoutGuideConstraintsToRemove", b.array(constraints))
            return (g, constraints)
        }
        let (top, topConstraints) = try guide("_UIViewControllerTop") { g in [
            try GeneratedConstraint(first: g, firstAttribute: .leading, second: root, secondAttribute: .leading).encode(b),
            try GeneratedConstraint(first: g, firstAttribute: .top, second: root, secondAttribute: .top).encode(b),
            try GeneratedConstraint(first: g, firstAttribute: .height).encode(b),
        ] }
        let (bottom, bottomConstraints) = try guide("_UIViewControllerBottom") { g in [
            try GeneratedConstraint(first: g, firstAttribute: .leading, second: root, secondAttribute: .leading).encode(b),
            try GeneratedConstraint(first: g, firstAttribute: .height).encode(b),
            try GeneratedConstraint(first: root, firstAttribute: .bottom, second: g, secondAttribute: .bottom).encode(b),
        ] }
        return Legacy(top: top, bottom: bottom, rootConstraints: topConstraints + bottomConstraints)
    }
}

/// `NSLayoutConstraint` attribute numbers (section 6 "NSLayoutConstraint").
enum LayoutAttribute: Int {
    case left = 1, right, top, bottom, leading, trailing, width, height, centerX, centerY
}

/// A constraint ibtool generates (not from the XML): no relation, multiplier or constant.
/// Keys: `NSFirstItem`, `NSFirstAttributeV2`, `NSFirstAttribute`, [`NSSecondItem`, `NSSecondAttributeV2`,
/// `NSSecondAttribute`], `NSShouldBeArchived`, [`NSPriority`], [`NSLayoutIdentifier`].
struct GeneratedConstraint {
    var first: ObjectRef
    var firstAttribute: LayoutAttribute
    var second: ObjectRef? = nil
    var secondAttribute: LayoutAttribute? = nil
    var archived = true
    var priority = 1000
    var identifier: String? = nil

    func encode(_ b: ArchiveBuilder, className: String = "NSLayoutConstraint", fallback: String? = nil) throws -> ObjectRef {
        let c = b.object(className, fallback: fallback)
        b.set(c, "NSFirstItem", first)
        b.set(c, "NSFirstAttributeV2", try ArchiveBuilder.int(firstAttribute.rawValue))
        b.set(c, "NSFirstAttribute", try ArchiveBuilder.int(firstAttribute.rawValue))
        if let second, let secondAttribute {
            b.set(c, "NSSecondItem", second)
            b.set(c, "NSSecondAttributeV2", try ArchiveBuilder.int(secondAttribute.rawValue))
            b.set(c, "NSSecondAttribute", try ArchiveBuilder.int(secondAttribute.rawValue))
        }
        b.set(c, "NSShouldBeArchived", .bool(archived))
        if priority != 1000 { b.set(c, "NSPriority", try ArchiveBuilder.int(priority)) }
        if let identifier { b.set(c, "NSLayoutIdentifier", b.string(identifier)) }
        return c
    }
}
