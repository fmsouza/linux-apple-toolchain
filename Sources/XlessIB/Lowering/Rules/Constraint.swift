import Foundation

/// Auto Layout constraints: `<constraint>` elements lowered to `NSLayoutConstraint` objects (docs/research/nib-encoding.md,
/// section 6 "NSLayoutConstraint"). Proving cases: `cons-*`, `order-cons-*`, `real-logo-plus-label`,
/// `real-background-logo-label`.
///
/// Keys, in order: `NSFirstItem`, `NSFirstAttributeV2`, `NSFirstAttribute`, [`NSRelation`], [`NSMultiplier`],
/// [`NSSecondItem`, `NSSecondAttributeV2`, `NSSecondAttribute`], [`NSSymbolicConstant`], [`NSConstantV2`],
/// `NSShouldBeArchived`, [`NSPriority`], [`NSLayoutIdentifier`], [`NSConstant`].
enum ConstraintRule {
    /// `<constraint>` attributes with a golden: `placeholder` and `identifier` by `cons-identifier-placeholder`,
    /// `symbolic` by `cons-symbolic`, `cons-symbolic-siblings`, the values by `cons-*-grid`.
    static let knownAttributes: Set<String> = [
        "id", "firstItem", "firstAttribute", "relation", "secondItem", "secondAttribute", "multiplier", "constant",
        "priority", "symbolic", "placeholder", "identifier",
    ]

    static let attributes: [String: LayoutAttribute] = [
        "left": .left, "right": .right, "top": .top, "bottom": .bottom, "leading": .leading, "trailing": .trailing,
        "width": .width, "height": .height, "centerX": .centerX, "centerY": .centerY,
    ]

    /// What a constraint item refers to, relative to the view owning the constraint.
    enum Item: Equatable {
        /// The owning view itself (also the implicit first item).
        case owner
        /// The root view's safe-area layout guide (only in the root view's list).
        case safeArea
        /// A direct subview of the owning view, by XML ID.
        case subview(String)
    }

    /// A checked constraint, ready to sort and encode.
    struct Plan {
        var id: String
        var first: Item
        var firstAttribute: LayoutAttribute
        var second: Item?
        var secondAttribute: LayoutAttribute?
        /// -1 for ≤, 1 for ≥, 0 for =.
        var relation: Int
        /// The float-rounded multiplier, nil when 1.
        var multiplier: Double?
        var constant: Double
        var symbolic: Bool
        var priority: Int
        var identifier: String?
        /// `placeholder="YES"`: removed at build time, but its items still count as constrained.
        var placeholder: Bool
        /// ibtool drops it from the nib (root view's width = item's height and vice versa) and its items do not count.
        var dropped: Bool
        var line: Int

        /// The XML IDs of the items, for the views' `UIViewDoesNotTranslateAutoresizingMaskIntoConstraints`.
        func itemIDs(ownerID: String) -> [String] {
            [first, second].compactMap { item in
                switch item {
                case .owner?: ownerID
                case .subview(let id)?: id
                case .safeArea?, nil: nil
                }
            }
        }
    }

    /// The view owning a `<constraints>` list, with what its constraints may refer to.
    struct Owner {
        var view: IBView
        var isRoot: Bool
        /// The safe-area guide's ID, for the root view in safe-area mode.
        var safeAreaID: String?
    }

    // MARK: Checking

    /// Checks every constraint of `owner`, in XML order (dropped and placeholder constraints included).
    static func plans(for owner: Owner) throws -> [Plan] {
        var seen = Set<String>()
        return try owner.view.constraints.map { c in
            let plan = try check(c, owner: owner)
            guard seen.insert(plan.id).inserted else {
                throw LoweringError.unsupported("duplicate constraint id \"\(plan.id)\"", line: c.line)
            }
            return plan
        }
    }

    static func check(_ c: IBConstraint, owner: Owner) throws -> Plan {
        let a = c.attributes, line = c.line
        try LoweringError.checkAttributes(a, known: knownAttributes, element: "constraint", line: line)
        guard let id = a["id"], !id.isEmpty else { throw LoweringError.unsupported("<constraint> without an id", line: line) }

        func attribute(_ key: String) throws -> LayoutAttribute? {
            guard let s = a[key] else { return nil }
            guard let attr = attributes[s] else {
                throw LoweringError.unsupported("constraint \(key)=\"\(s)\" (supported: edges, leading/trailing, width/height, centers; not margins or baselines)", line: line)
            }
            return attr
        }
        guard let firstAttribute = try attribute("firstAttribute") else {
            throw LoweringError.unsupported("<constraint> without firstAttribute", line: line)
        }
        let secondAttribute = try attribute("secondAttribute")
        // leading/trailing paired with left/right: ibtool rewrites the attributes (`cons-mixed-horizontal`: leading =
        // left becomes leading = leading) and UIKit rejects such a constraint at run time.
        let directional: Set<LayoutAttribute> = [.leading, .trailing], absolute: Set<LayoutAttribute> = [.left, .right]
        if let s = secondAttribute,
           directional.contains(firstAttribute) && absolute.contains(s) || absolute.contains(firstAttribute) && directional.contains(s) {
            throw LoweringError.unsupported("constraint pairing firstAttribute=\"\(a["firstAttribute"]!)\" with secondAttribute=\"\(a["secondAttribute"]!)\" (leading/trailing cannot be mixed with left/right; ibtool rewrites it)", line: line)
        }
        let first = try item(a["firstItem"], owner: owner, line: line) ?? .owner
        let second = try item(a["secondItem"], owner: owner, line: line)
        guard (second == nil) == (secondAttribute == nil) else {
            throw LoweringError.unsupported("constraint with \(second == nil ? "secondAttribute but no secondItem" : "secondItem but no secondAttribute")", line: line)
        }

        // Proven shapes: an item against another item or the owner; the owner's own size (no second item); the
        // owner against itself (aspect ratio, `order-cons-own`, `order-cons-owner-first`).
        if second == nil {
            guard first == .owner, firstAttribute == .width || firstAttribute == .height else {
                throw LoweringError.unsupported("constraint without a second item on \(first == .owner ? "\(firstAttribute)" : "another view") (supported: a view's own width or height)", line: line)
            }
        }
        if let second, second == first, first != .owner {
            throw LoweringError.unsupported("constraint between a view and itself outside that view's own constraints", line: line)
        }
        // A constraint on the root view alone (its own size, or root against root): the root view is sized by the
        // device, and no golden has one.
        if owner.isRoot, first == .owner, second == nil || second == .owner {
            throw LoweringError.unsupported("constraint on the root view's own size", line: line)
        }

        let relation: Int
        switch a["relation"] {
        case nil: relation = 0
        case "lessThanOrEqual": relation = -1
        case "greaterThanOrEqual": relation = 1
        case let r?: throw LoweringError.unsupported("constraint relation=\"\(r)\"", line: line)
        }
        let symbolic = try LoweringError.bool(a, "symbolic", line: line)
        if symbolic == false { throw LoweringError.unsupported("constraint symbolic=\"NO\" (Xcode does not write it)", line: line) }
        let constant = try a["constant"].map { try decimal($0, what: "constant", line: line) } ?? 0
        if symbolic == true, a["constant"] == nil {
            throw LoweringError.unsupported("symbolic constraint without a constant (Xcode writes the standard value)", line: line)
        }
        let placeholder = try LoweringError.bool(a, "placeholder", line: line)
        if placeholder == false { throw LoweringError.unsupported("constraint placeholder=\"NO\" (Xcode does not write it)", line: line) }
        let identifier = a["identifier"]
        if identifier == "" { throw LoweringError.unsupported("constraint with an empty identifier", line: line) }

        // `root.width = item.height` and `root.height = item.width` (root first, written or implicit) are not in the
        // nib, whatever the item, relation, multiplier, constant or priority (`cons-dropped-root-size`,
        // `order-cons-table-superview-flipped`); a subview owner keeps them.
        let crossSize = [firstAttribute, secondAttribute] == [.width, .height] || [firstAttribute, secondAttribute] == [.height, .width]
        let dropped = owner.isRoot && first == .owner && second != nil && second != .owner && crossSize
        if dropped, placeholder == true {
            throw LoweringError.unsupported("placeholder constraint that ibtool drops (root view width = item height)", line: line)
        }

        return Plan(id: id, first: first, firstAttribute: firstAttribute, second: second, secondAttribute: secondAttribute,
                    relation: relation, multiplier: try multiplier(a["multiplier"], line: line), constant: constant,
                    symbolic: symbolic == true, priority: try priority(a["priority"], line: line), identifier: identifier,
                    placeholder: placeholder == true, dropped: dropped, line: line)
    }

    /// Resolves an item ID: the owner, its safe-area guide, or one of its direct subviews. Other items (a deeper
    /// view, open question 7; a legacy layout guide; another view's guide) are refused.
    static func item(_ id: String?, owner: Owner, line: Int) throws -> Item? {
        guard let id else { return nil }
        if id == owner.view.id { return .owner }
        if let safe = owner.safeAreaID, id == safe { return .safeArea }
        if owner.view.subviews.contains(where: { $0.id == id }) { return .subview(id) }
        throw LoweringError.openQuestion("constraint item \"\(id)\" is not the owning view, its safe area or one of its direct subviews", line: line,
                                         fix: "let Xcode place the constraint (it belongs to the nearest common superview of its items)")
    }

    /// A constant or ratio component in Xcode's spelling (`XcodeNumber`): an optional minus, digits without leading
    /// zeros, an optional fraction.
    static func decimal(_ s: String, what: String, line: Int) throws -> Double {
        guard let v = XcodeNumber.parse(s, negativeZero: what == "constant") else {
            throw LoweringError.unsupported("constraint \(what)=\"\(s)\"", line: line)
        }
        return v
    }

    /// `NSMultiplier`: a decimal is rounded to six significant digits (C `%g`) and then to float; a ratio `a:b` or
    /// `a/b` is divided exactly and rounded to float (`cons-multiplier-grid`: 0.33333333333333331 → 0.333333 →
    /// 0.33333298563957214; 16:9 → 1.7777777910232544). Nil when the value is 1.
    static func multiplier(_ s: String?, line: Int) throws -> Double? {
        guard let s else { return nil }
        func refuse(_ why: String) -> Error {
            LoweringError.unsupported("constraint multiplier=\"\(s)\" (\(why))", line: line)
        }
        let value: Float
        let exact: Bool
        if let sep = s.firstIndex(where: { $0 == ":" || $0 == "/" }) {
            let n = try decimal(String(s[..<sep]), what: "multiplier", line: line)
            let d = try decimal(String(s[s.index(after: sep)...]), what: "multiplier", line: line)
            guard n > 0, d > 0 else { throw refuse("supported: positive ratios") }
            // Both components survive `%g` unchanged and float division agrees with double division rounded to
            // float, so the result does not depend on how ibtool evaluates the ratio.
            guard [n, d].allSatisfy({ sixDigits($0).flatMap(Double.init) == $0 }) else { throw refuse("ratio components need at most six significant digits") }
            value = Float(n / d)
            guard value.isFinite, value > 0, Float(n) / Float(d) == value else { throw refuse("the ratio's float value depends on the evaluation order") }
            exact = n == d
        } else {
            let v = try decimal(s, what: "multiplier", line: line)
            guard v > 0 else { throw refuse("supported: positive values") }
            guard let g = sixDigits(v), let f = Float(g), let viaDouble = Double(g) else { throw refuse("supported: 0.0001 up to 999999.5") }
            guard Float(viaDouble) == f else { throw refuse("its float value depends on the evaluation order") }
            value = f
            exact = v == 1
        }
        if value == 1 {
            guard exact else { throw refuse("rounds to 1; whether ibtool then omits it is unverified") }
            return nil
        }
        return Double(value)
    }

    /// `v` rounded to six significant digits by C's `%g`, or nil when `%g` switches to an exponent (below 1e-4, from
    /// 1e6): ibtool then encodes 1 (1234567.8 in a scratch run).
    static func sixDigits(_ v: Double) -> String? {
        let g = String(format: "%g", v)
        return g.contains("e") ? nil : g
    }

    /// `NSPriority`: whole numbers 1–1000 (1000, the default, is omitted; `cons-values-grid`, `cons-priority-*`).
    static func priority(_ s: String?, line: Int) throws -> Int {
        guard let s else { return 1000 }
        guard let p = Int(s), String(p) == s, (1...1000).contains(p) else {
            throw LoweringError.unsupported("constraint priority=\"\(s)\" (supported: whole numbers 1–1000)", line: line)
        }
        return p
    }

    // MARK: Order

    /// Attribute ranks used by the sort (centerX 0, right 1, left 2, trailing 3, leading 4, width 5, centerY 6,
    /// bottom 7, top 8, height 9).
    static let rank: [LayoutAttribute: Int] = [
        .centerX: 0, .right: 1, .left: 2, .trailing: 3, .leading: 4, .width: 5, .centerY: 6, .bottom: 7, .top: 8, .height: 9,
    ]

    /// The documented sort of a view's constraint array (section 6, "Constraint array order"), steps 1–6 and 8, of
    /// the constraints that are encoded (neither dropped nor placeholders). Two constraints that tie through step 6
    /// are refused when their (other) second items differ (step 7, open question 1), or when only one of them is
    /// written from the owning view (open question 13).
    static func sorted(_ plans: [Plan], owner: IBView) throws -> [Plan] {
        let origins = Dictionary(owner.subviews.compactMap { v in v.frame.map { (v.id, ($0.x, $0.y)) } }, uniquingKeysWith: { a, _ in a })
        // The safe-area guide counts as (0, 0) and ties with subviews at the origin by its ID (`order-cons-items-geometry`).
        let guideID = owner.safeArea?.id ?? ""
        struct Key {
            var first: (Double, Double, [UInt8])
            var other: Bool
            var attrs: (Int, Int, Int)
            var priority: Int
            var relation: Int
            var second: Item?
            /// Step 1 swapped the items (the constraint is written from the owning view).
            var swapped: Bool
            var id: [UInt8]
        }
        func key(_ p: Plan) -> Key {
            var (a, b) = (p.first, p.second)
            let swapped = a == .owner && b != nil && b != .owner
            if swapped, let s = b { (a, b) = (s, .owner) }
            let other = b != nil && b != .owner
            let firstKey: (Double, Double, [UInt8])
            switch a {
            case .owner: firstKey = (-1, 0, [])   // the owner sorts first (`order-cons-owner-first`)
            case .safeArea: firstKey = (0, 0, Array(guideID.utf8))
            case .subview(let id):
                let (x, y) = origins[id] ?? (0, 0)
                firstKey = (x * x + y * y, x, Array(id.utf8))
            }
            let fa = rank[p.firstAttribute]!, sa = p.secondAttribute.map { rank[$0]! } ?? -1
            let attrs: (Int, Int, Int)
            if other {
                let sameSize = p.firstAttribute == p.secondAttribute && (p.firstAttribute == .width || p.firstAttribute == .height)
                attrs = (sameSize ? 1 : 0, fa, sa)
            } else {
                let both = [p.firstAttribute, p.secondAttribute]
                let category = both.contains(.centerX) ? 0 : both.contains(.centerY) ? 1
                    : [.right, .left].contains(p.firstAttribute) ? 2 : [.trailing, .leading].contains(p.firstAttribute) ? 3
                    : p.firstAttribute == .width ? 4 : [.bottom, .top].contains(p.firstAttribute) ? 5 : 6
                attrs = (category, fa, sa)
            }
            return Key(first: firstKey, other: other, attrs: attrs, priority: p.priority,
                       relation: [-1: 0, 1: 1, 0: 2][p.relation]!, second: other ? b : nil, swapped: swapped, id: Array(p.id.utf8))
        }
        let keyed = plans.map { (plan: $0, key: key($0)) }
        func lessThroughStep6(_ x: Key, _ y: Key) -> Bool? {
            if x.first.0 != y.first.0 { return x.first.0 < y.first.0 }
            if x.first.1 != y.first.1 { return x.first.1 < y.first.1 }
            if x.first.2 != y.first.2 { return x.first.2.lexicographicallyPrecedes(y.first.2) }
            if x.other != y.other { return !x.other }
            if x.attrs != y.attrs { return x.attrs < y.attrs }
            if x.priority != y.priority { return x.priority < y.priority }
            if x.relation != y.relation { return x.relation < y.relation }
            return nil
        }
        let result = keyed.sorted { x, y in
            lessThroughStep6(x.key, y.key) ?? x.key.id.lexicographicallyPrecedes(y.key.id)
        }
        // Ties through step 6 are ordered by id (step 8) only when both constraints have the same second item and are
        // written in the same direction; otherwise ibtool's order is unknown (open questions 1 and 13).
        for (x, y) in zip(result, result.dropFirst()) where lessThroughStep6(x.key, y.key) == nil {
            let fix = "give one of them a different priority or relation, or remove the redundant constraint"
            if x.key.second != y.key.second {
                throw LoweringError.openQuestion(
                    "constraints \"\(x.plan.id)\" and \"\(y.plan.id)\" differ only in their second items, whose order in ibtool's output is unknown",
                    line: y.plan.line, fix: fix)
            }
            if x.key.swapped != y.key.swapped {
                throw LoweringError.openQuestion(
                    "constraints \"\(x.plan.id)\" and \"\(y.plan.id)\" tie but are written in opposite directions (one from the owning view), so their order in ibtool's output is unknown",
                    line: y.plan.line, fix: fix)
            }
        }
        return result.map(\.plan)
    }

    // MARK: Encoding

    /// Encodes `plan`; `ref` maps its items to objects (the owner, the safe-area guide, subviews).
    static func encode(_ plan: Plan, ref: (Item) -> ObjectRef, into b: ArchiveBuilder) throws -> ObjectRef {
        let c = b.object("NSLayoutConstraint")
        b.set(c, "NSFirstItem", ref(plan.first))
        b.set(c, "NSFirstAttributeV2", try ArchiveBuilder.int(plan.firstAttribute.rawValue))
        b.set(c, "NSFirstAttribute", try ArchiveBuilder.int(plan.firstAttribute.rawValue))
        if plan.relation != 0 { b.set(c, "NSRelation", try ArchiveBuilder.int(plan.relation)) }
        if let m = plan.multiplier { b.set(c, "NSMultiplier", .double(m)) }
        if let second = plan.second, let attr = plan.secondAttribute {
            b.set(c, "NSSecondItem", ref(second))
            b.set(c, "NSSecondAttributeV2", try ArchiveBuilder.int(attr.rawValue))
            b.set(c, "NSSecondAttribute", try ArchiveBuilder.int(attr.rawValue))
        }
        // A symbolic constraint (standard spacing) keeps no constant (`cons-symbolic`, `cons-symbolic-siblings`).
        let constant = plan.symbolic ? 0 : plan.constant
        if plan.symbolic { b.set(c, "NSSymbolicConstant", b.string("NSSpace")) }
        if constant != 0 { b.set(c, "NSConstantV2", .double(constant)) }
        b.set(c, "NSShouldBeArchived", .bool(true))
        if plan.priority != 1000 { b.set(c, "NSPriority", try ArchiveBuilder.int(plan.priority)) }
        if let identifier = plan.identifier { b.set(c, "NSLayoutIdentifier", b.string(identifier)) }
        if constant != 0 { b.set(c, "NSConstant", .double(constant)) }
        return c
    }
}
