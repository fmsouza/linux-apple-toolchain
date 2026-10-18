import Foundation
import XlessCore

/// Lowers the root view and everything under it into `<vcID>-view-<viewID>.nib` (docs/research/nib-encoding.md,
/// sections 3 and 6). Object numbering, key and class tables are left to `ArchiveBuilder.finish(root:)`; this type
/// builds the object graph and the objects list (`UINibObjectsKey`).
final class ViewNibLowering {
    let doc: IBDocument
    let options: IBCompileOptions
    /// The image's Xcode: whose ibtool output this nib reproduces.
    let profile: XcodeToolsProfile
    /// How this view nib is encoded under that Xcode (`profile.nibPlainViews` or `profile.nibOtherViews`, set by `lower`).
    private(set) var encoding: XcodeToolsProfile.NibEncoding
    let b = ArchiveBuilder()
    private(set) var warnings: [String] = []
    /// The point sizes of the italic system fonts encoded so far (`FontEncoding`, `checkItalicSizes`).
    var italicSizes = Set<Double>()

    init(doc: IBDocument, options: IBCompileOptions, profile: XcodeToolsProfile) {
        self.doc = doc
        self.options = options
        self.profile = profile
        self.encoding = profile.nibOtherViews
    }

    /// Whether the view nib of `root` is one of plain views: safe-area layout (no legacy top/bottom guides) and no label
    /// or image view anywhere in the tree. Xcode 26.2 encodes those differently from every other view nib (the LNE key,
    /// its own system color table; docs/research/xcode-tools-by-version.md, "Compiled nib differences": in its goldens
    /// the view nibs carrying `IBUINibLNEVersionKey` are exactly these).
    static func isPlainViews(_ root: IBView, doc: IBDocument) -> Bool {
        guard doc.useSafeAreas || root.safeArea != nil else { return false }
        func plain(_ v: IBView) -> Bool { v.kind == .view && v.subviews.allSatisfy(plain) }
        return plain(root)
    }

    /// Under a profile that shares the italic traits dictionary per optical-size band, two italic system fonts of
    /// different sizes need every size to be in a measured band: whether they share it is not known otherwise.
    func checkItalicSizes() throws {
        guard case let .opticalSizeBands(low, high, between) = encoding.italicTraits, italicSizes.count > 1 else { return }
        let sizes = italicSizes.sorted()
        func pt(_ v: Double) -> String { String(format: "%g", v) }
        if let unmeasured = sizes.first(where: { !($0 <= low || $0 >= high || between.contains($0)) }) {
            let list = sizes.map { pt($0) }
            let shown = list.count == 2 ? "\(list[0]) and \(list[1])" : list.dropLast().joined(separator: ", ") + " and " + list.last!
            throw XlessError(.ib, "unsupported: italic system fonts of \(shown) pt in one storyboard under Xcode \(profile.xcodeVersion) (\(profile.xcodeBuild)): whether that ibtool shares their traits dictionary is measured only for \(pt(low)) pt or less, \(between.map { pt($0) }.joined(separator: ", ")) pt and \(pt(high)) pt or more, not \(pt(unmeasured)) pt (see docs/research/xcode-tools-by-version.md)",
                             fix: "use italic sizes of 13 pt or less, 20 pt, or 28 pt or more, or a single italic size")
        }
    }

    /// A lowered subview: its object, its entry in the objects list (`[its constraints…, its subviews…]`) and its
    /// lowered subviews.
    struct Lowered {
        var ref: ObjectRef
        var entry: [ObjectRef]
        var subviews: [Lowered]
        /// The view's accessibility traits (`AccessibilityRule`), nil without an `<accessibility>` element.
        var accessibilityTraits: Int?

        /// The objects list after the root's entry: the subviews' entries breadth-first, level by level and in subview
        /// order within a level (`order-objects-bfs`: root → A{A1{A11}}, B{B1} lists A, B, then A1, then B1, then A11).
        static func breadthFirst(_ subviews: [Lowered]) -> [ObjectRef] {
            var queue = subviews, out: [ObjectRef] = [], i = 0
            while i < queue.count {
                out += queue[i].entry
                queue += queue[i].subviews
                i += 1
            }
            return out
        }

        /// The views of `subviews` with accessibility traits, in the same breadth-first order (`acc-kinds-order`).
        static func accessibilityBreadthFirst(_ subviews: [Lowered]) -> [(ref: ObjectRef, traits: Int)] {
            var queue = subviews, out: [(ref: ObjectRef, traits: Int)] = [], i = 0
            while i < queue.count {
                if let t = queue[i].accessibilityTraits { out.append((queue[i].ref, t)) }
                queue += queue[i].subviews
                i += 1
            }
            return out
        }
    }

    func lower(_ rootView: IBView) throws -> NIBArchive {
        encoding = Self.isPlainViews(rootView, doc: doc) ? profile.nibPlainViews : profile.nibOtherViews
        try ViewRule.checkSupported(rootView, isRoot: true, lowering: self)
        try prepareConstraints(rootView)
        let owner = b.proxy("IBFilesOwner"), responder = b.proxy("IBFirstResponder")
        let root = b.object("UIView")
        rootRef = root
        let subviews = try rootView.subviews.map(lowerSubview)
        let constraints = try encodeConstraints(of: rootView, ref: root, subviews: subviews)
        let size = try RootSize.size(of: rootView, doc: doc, options: options)
        var parts = ViewRule.Parts(size: size, center: (size.width / 2, size.height / 2), subviews: subviews.map(\.ref))
        var entry: [ObjectRef]
        // Safe-area mode: `useSafeAreas="YES"` or a safe-area guide on the root view (`core-safearea-attr-only`,
        // `core-safearea-guide-only`); otherwise the legacy top/bottom guides (`core-minimal`).
        if doc.useSafeAreas || rootView.safeArea != nil {
            // The placeholder guide comes right after the root view, before its constraints (`real-logo-plus-label`).
            entry = [LayoutGuideRule.safeAreaPlaceholder(b)] + constraints + subviews.map(\.ref)
            parts.constraints = constraints
            if let guide = safeAreaGuide { parts.layoutGuides = [guide] }
        } else {
            // The legacy guides come after the root's own constraints and before its subviews; their constraints
            // come first in the root's array (`core-legacy-constraints`).
            let legacy = try LayoutGuideRule.legacyGuides(b, root: root)
            parts.subviews += [legacy.top, legacy.bottom]
            parts.constraints = legacy.rootConstraints + constraints
            entry = constraints + [legacy.top, legacy.bottom] + subviews.map(\.ref)
        }
        entry += Lowered.breadthFirst(subviews)
        try ViewRule.encode(rootView, into: root, parts: parts, lowering: self)
        // Accessibility configurations last: they are encoded after the views (their traits number reuses a font's).
        let accessible = (try AccessibilityRule.value(rootView).map { [(ref: root, traits: $0)] } ?? [])
            + Lowered.accessibilityBreadthFirst(subviews)
        let configurations = try AccessibilityRule.encode(accessible, into: b)
        try checkItalicSizes()
        let top = [owner, responder, root]
        let nibRoot = b.nibRoot(topLevel: top, objects: top + entry, connections: [b.outlet("view", source: owner, destination: root)],
                                accessibilityConfigurations: configurations, lneVersionKey: encoding.writesLNEVersionKey)
        var archive = try b.finish(root: nibRoot)
        // The `LNE\0` after the class names comes with the key: Xcode 26.2's view nibs without it end at the class names.
        if !encoding.writesLNEVersionKey { archive.trailer = Data() }
        return archive
    }

    func lowerSubview(_ v: IBView) throws -> Lowered {
        var label: LabelRule.Plan?
        switch v.kind {
        case .view: try ViewRule.checkSupported(v, isRoot: false, lowering: self)
        case .imageView: try ImageViewRule.checkSupported(v, lowering: self)
        case .label: label = try LabelRule.checkSupported(v, lowering: self)
        }
        guard let f = v.frame else { throw LoweringError.unsupported("<\(v.kind.rawValue)> without a frame", line: v.line) }
        let className = switch v.kind { case .view: "UIView"; case .imageView: "UIImageView"; case .label: "UILabel" }
        let ref = b.object(className)
        let subviews = try v.subviews.map(lowerSubview)
        let constraints = try encodeConstraints(of: v, ref: ref, subviews: subviews)
        // Subview frames are used verbatim; the center is computed in double (`image-frame-fraction`).
        let parts = ViewRule.Parts(size: (f.width, f.height), center: (f.x + f.width / 2, f.y + f.height / 2), subviews: subviews.map(\.ref),
                                   constraints: constraints, constrained: constrainedIDs.contains(v.id))
        switch v.kind {
        case .view: try ViewRule.encode(v, into: ref, parts: parts, lowering: self)
        case .imageView: try ImageViewRule.encode(v, into: ref, parts: parts, lowering: self)
        case .label: try LabelRule.encode(v, plan: label!, into: ref, parts: parts, lowering: self)
        }
        return Lowered(ref: ref, entry: constraints + subviews.map(\.ref), subviews: subviews,
                       accessibilityTraits: try AccessibilityRule.value(v))
    }

    // MARK: Constraints

    /// The encoded constraints of each view (by XML ID), in array order; filled by `prepareConstraints(_:)`.
    private var constraintPlans: [String: [ConstraintRule.Plan]] = [:]
    /// IDs of the views that are the first or second item of a constraint that is not dropped (placeholders count,
    /// `cons-identifier-placeholder`); a constraint without `firstItem` has the view owning it as its first item
    /// (`cons-implicit-firstitem`). Owning constraints between other items does not count (`cons-owner-not-item`).
    private var constrainedIDs = Set<String>()
    private var rootRef: ObjectRef?
    /// The root view's owned safe-area guide, made when a constraint first refers to it.
    private var safeAreaGuide: ObjectRef?

    /// Checks every constraint of the tree before anything is encoded: which views are constrained must be known
    /// when a view is encoded, and a constraint may refer to a view encoded later.
    func prepareConstraints(_ root: IBView) throws {
        // Items are found by ID, so views and the safe-area guide must have distinct IDs (Xcode never repeats one).
        var ids = Set<String>()
        func collect(_ v: IBView) throws {
            for id in [v.id] + (v.safeArea.map { [$0.id] } ?? []) where !ids.insert(id).inserted {
                throw LoweringError.unsupported("duplicate id \"\(id)\"", line: v.line)
            }
            for s in v.subviews { try collect(s) }
        }
        try collect(root)
        func visit(_ v: IBView, isRoot: Bool) throws {
            let owner = ConstraintRule.Owner(view: v, isRoot: isRoot, safeAreaID: isRoot ? v.safeArea?.id : nil)
            let plans = try ConstraintRule.plans(for: owner)
            for p in plans where !p.dropped { constrainedIDs.formUnion(p.itemIDs(ownerID: v.id)) }
            // The owned safe-area guide is made only when an encoded constraint refers to it: a safe area used only
            // by placeholder or dropped constraints gets none (`cons-placeholder-safearea`, `cons-dropped-root-size`).
            constraintPlans[v.id] = try ConstraintRule.sorted(plans.filter { !$0.dropped && !$0.placeholder }, owner: v)
            for s in v.subviews { try visit(s, isRoot: false) }
        }
        try visit(root, isRoot: true)
    }

    /// Encodes the constraints of `v` (whose object is `ref` and whose lowered subviews are `subviews`).
    func encodeConstraints(of v: IBView, ref: ObjectRef, subviews: [Lowered]) throws -> [ObjectRef] {
        let subviewRefs = Dictionary(zip(v.subviews.map(\.id), subviews.map(\.ref)), uniquingKeysWith: { a, _ in a })
        return try (constraintPlans[v.id] ?? []).map { plan in
            try ConstraintRule.encode(plan, ref: { item in
                switch item {
                case .owner: return ref
                case .subview(let id): return subviewRefs[id]!
                case .safeArea:
                    if let g = safeAreaGuide { return g }
                    let g = LayoutGuideRule.ownedSafeAreaGuide(b, root: rootRef!)
                    safeAreaGuide = g
                    return g
                }
            }, into: b)
        }
    }
}

/// The root view's size (docs/research/nib-encoding.md, section 6 "UIView (root view)"; `device-*`, `core-frame-*`,
/// `core-no-traitcollections`, section 8): the `<device>` decides; without a known device, deployment target ≥ 17 uses
/// the XML frame, below 17 it is 600 × 600 with trait collections, else 393 × 852.
enum RootSize {
    static let devices: [String: (Double, Double)] = [
        "retina4_0": (320, 568), "retina4_7": (375, 667), "retina5_5": (414, 736), "retina5_9": (375, 812),
        "retina6_0": (390, 844), "retina6_1": (414, 896), "retina6_5": (414, 896), "retina6_7": (430, 932),
        "retina6_12": (393, 852), "retina6_3": (402, 874), "retina6_9": (440, 956),
        "ipad9_7": (768, 1024), "ipad10_2": (810, 1080), "ipad10_9rounded": (820, 1180),
        "ipad11_0rounded": (834, 1210), "ipad12_9rounded": (1024, 1366),
        "retina3_5": (393, 852),   // retired id, sized like the default device (`device-retina3_5`)
    ]
    /// Device ids that count as no device (`device-unknown`). Other ids are an open question (4).
    static let noDevice: Set<String> = ["unknownDevice"]
    static let deviceAttributes: Set<String> = ["id", "orientation", "appearance"]

    static func size(of root: IBView, doc: IBDocument, options: IBCompileOptions) throws -> (width: Double, height: Double) {
        if let device = doc.raw.children.first(where: { $0.name == "device" }) {
            try LoweringError.checkAttributes(device.attributes, known: deviceAttributes, element: "device", line: device.line)
            // `appearance` light, dark or absent, and an `<adaptation id="fullscreen"/>` child, give identical nibs
            // (`device-appearance-dark`, `device-no-appearance`, `device-adaptation-fullscreen`).
            if let ap = device.attributes["appearance"], ap != "light", ap != "dark" {
                throw LoweringError.unsupported("device appearance \"\(ap)\"", line: device.line)
            }
            for c in device.children {
                guard c.name == "adaptation", c.attributes == ["id": "fullscreen"] else {
                    throw LoweringError.unsupported("<\(c.name) \(ColorRule.describe(c.attributes, keepKey: true))>", line: c.line)
                }
            }
            let id = device.attributes["id"] ?? ""
            if let (w, h) = devices[id] {
                switch device.attributes["orientation"] {
                case nil, "portrait": return (w, h)
                case "landscape": return (h, w)
                case let o?: throw LoweringError.unsupported("device orientation \"\(o)\"", line: device.line)
                }
            }
            guard noDevice.contains(id) else {
                throw LoweringError.openQuestion("device id \"\(id)\" (its size in ibtool is unknown)", line: device.line,
                                                 fix: "pick a current iPhone in Interface Builder's device bar (e.g. iPhone 16) and save")
            }
        }
        if DottedVersion(options.minimumDeploymentTarget)! >= DottedVersion("17.0")! {
            guard let f = root.frame else { throw LoweringError.unsupported("root view without a frame", line: root.line) }
            return (f.width, f.height)
        }
        return doc.useTraitCollections ? (600, 600) : (393, 852)
    }
}
