import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import XlessCore

public enum StoryboardParser {
    /// Launch-screen storyboards are a few KB; larger input is refused before it is read or parsed.
    static let maxInputSize = 4 << 20
    /// Views nested deeper than this (the root view is level 1) are refused while parsing, before anything recurses
    /// over the tree (`nesting-32-levels` proves level 32).
    static let maxViewDepth = 32

    static func checkSize(_ size: Int) throws {
        guard size <= maxInputSize else {
            throw XlessError(.ib, "unsupported: storyboard of \(size) bytes (launch screens over \(maxInputSize) bytes are not supported)",
                             fix: "launch-screen storyboards are a few KB; check that the right file is configured")
        }
    }

    public static func parse(url: URL) throws -> IBDocument {
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber {
            try checkSize(size.intValue)
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw XlessError(.ib, "cannot read storyboard \(url.path): \(error.localizedDescription)", fix: "check the path")
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> IBDocument {
        try checkSize(data.count)
        let collector = TreeCollector(data: data)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let ok = parser.parse()
        if let e = collector.failure { throw e }
        guard ok, let root = collector.root else {
            let msg = parser.parserError?.localizedDescription ?? "unknown error"
            throw XlessError(.ib, "invalid storyboard XML at line \(parser.lineNumber): \(msg)", fix: "open and re-save it in Xcode")
        }
        return try Lowerer.document(root)
    }

    static let unsupportedFix = "launch-screen storyboards support: viewController, view, imageView, label, constraints, colors, safe area (see docs/xless-yml.md)"

    static func unsupported(_ name: String, line: Int) -> XlessError {
        XlessError(.ib, "unsupported element <\(name)> at line \(line)", fix: unsupportedFix)
    }

    /// Permitted child elements per parent, matching what Xcode writes for the supported subset.
    /// The empty-string key lists the permitted root.
    static let children: [String: Set<String>] = {
        let viewContent: Set<String> = ["subviews", "rect", "autoresizingMask", "viewLayoutGuide", "color",
                                        "fontDescription", "nil", "constraints", "accessibility"]
        return [
            "": ["document"],
            "document": ["device", "dependencies", "scenes", "resources"],
            "device": ["adaptation"],
            "dependencies": ["deployment", "plugIn", "capability"],
            "scenes": ["scene"],
            "scene": ["objects", "point"],
            "objects": ["viewController", "placeholder"],
            "viewController": ["view", "layoutGuides", "connections"],
            "placeholder": ["connections"],
            "connections": ["layoutGuides"],
            "layoutGuides": ["viewControllerLayoutGuide"],
            "view": viewContent, "imageView": viewContent.union(["imageReference"]), "label": viewContent.union(["string"]),
            "subviews": ["view", "imageView", "label"],
            "constraints": ["constraint"],
            "resources": ["systemColor", "namedColor", "image"],
            "systemColor": ["color"], "namedColor": ["color"],
            "accessibility": ["accessibilityTraits"],
        ]
    }()

    /// Elements that may repeat under one parent; every other element is a singleton per (name, key).
    static let repeatable: Set<String> = [
        "scene", "placeholder", "constraint", "plugIn", "capability", "deployment",
        "systemColor", "namedColor", "image", "viewControllerLayoutGuide", "adaptation",
    ]
    static let viewKinds: Set<String> = ["view", "imageView", "label"]
    /// Elements that are only allowed with one `key`: `<string key="text">` (label text containing a newline),
    /// `<imageReference key="image">` (Xcode's image-reference form) and the accessibility traits
    /// (`<accessibility key="accessibilityConfiguration">` with `<accessibilityTraits key="traits">`).
    static let requiredKey: [String: String] = [
        "string": "text", "imageReference": "image", "accessibility": "accessibilityConfiguration", "accessibilityTraits": "traits",
    ]
}

/// Generic element tree; the allow-list is enforced while it is built.
final class XMLNode {
    let name: String
    let attributes: [String: String]
    let line: Int
    let path: [Int]
    var children: [XMLNode] = []
    var seen = Set<String>()
    /// Character content; non-nil only for elements whose text is kept (`<string>`).
    var text: String?
    init(name: String, attributes: [String: String], line: Int, path: [Int]) {
        self.name = name; self.attributes = attributes; self.line = line; self.path = path
    }
    func children(named n: String) -> [XMLNode] { children.filter { $0.name == n } }
    func child(named n: String) -> XMLNode? { children.first { $0.name == n } }
    var raw: IBRawElement {
        IBRawElement(name: name, attributes: attributes, children: children.map(\.raw), line: line, text: text)
    }
}

/// `XMLParser.lineNumber` reports where a start tag ends. This scans the source for the
/// `<` of each start tag, in document order, so every element gets its true start line.
private struct StartTagScanner {
    var tags: [(name: String, line: Int)] = []

    init(_ data: Data) {
        let b = [UInt8](data)
        let n = b.count
        var i = 0, line = 1, counted = 0
        func advanceLine(to pos: Int) {
            while counted < pos {
                if b[counted] == 0x0A { line += 1 }
                else if b[counted] == 0x0D, !(counted + 1 < n && b[counted + 1] == 0x0A) { line += 1 }
                counted += 1
            }
        }
        func has(_ s: StaticString, at p: Int) -> Bool {
            let count = s.utf8CodeUnitCount
            guard p + count <= n else { return false }
            return s.withUTF8Buffer { u in (0..<count).allSatisfy { b[p + $0] == u[$0] } }
        }
        func find(_ s: StaticString, from p: Int) -> Int? {
            var q = p
            while q < n { if has(s, at: q) { return q }; q += 1 }
            return nil
        }
        while i < n {
            guard b[i] == 0x3C else { i += 1; continue }
            if has("<!--", at: i) { guard let e = find("-->", from: i + 4) else { return }; i = e + 3 }
            else if has("<![CDATA[", at: i) { guard let e = find("]]>", from: i + 9) else { return }; i = e + 3 }
            else if has("<?", at: i) { guard let e = find("?>", from: i + 2) else { return }; i = e + 2 }
            else if has("<!", at: i) {
                var depth = 0, q = i + 2
                while q < n, !(b[q] == 0x3E && depth == 0) {
                    if b[q] == 0x5B { depth += 1 } else if b[q] == 0x5D { depth -= 1 }
                    q += 1
                }
                i = q + 1
            } else if has("</", at: i) { guard let e = find(">", from: i) else { return }; i = e + 1 }
            else {
                var q = i + 1
                while q < n, ![0x20, 0x09, 0x0A, 0x0D, 0x2F, 0x3E].contains(b[q]) { q += 1 }
                advanceLine(to: i)
                tags.append((String(decoding: b[(i + 1)..<q], as: UTF8.self), line))
                var quote: UInt8?
                while q < n {
                    let c = b[q]
                    if let qu = quote { if c == qu { quote = nil } }
                    else if c == 0x22 || c == 0x27 { quote = c }
                    else if c == 0x3E { break }
                    q += 1
                }
                i = q + 1
            }
        }
    }
}

private final class TreeCollector: NSObject, XMLParserDelegate {
    var root: XMLNode?
    var failure: XlessError?
    private var stack: [XMLNode] = []
    private let scanned: [(name: String, line: Int)]
    private var index = 0
    /// Number of view elements (`view`, `imageView`, `label`) on the stack.
    private var viewDepth = 0

    init(data: Data) {
        scanned = StartTagScanner(data).tags
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        // Prefer the scanned start line; fall back to the parser's if the scan disagrees (e.g. odd encodings).
        let line = index < scanned.count && scanned[index].name == elementName ? scanned[index].line : parser.lineNumber
        index += 1
        let parentName = stack.last?.name ?? ""
        if StoryboardParser.viewKinds.contains(elementName) {
            guard viewDepth < StoryboardParser.maxViewDepth else {
                return fail(parser, XlessError(.ib, "unsupported: views nested deeper than \(StoryboardParser.maxViewDepth) levels at line \(line)",
                                               fix: "flatten the view hierarchy (launch screens need only a few levels)"))
            }
            viewDepth += 1
        }
        guard StoryboardParser.children[parentName]?.contains(elementName) == true,
              StoryboardParser.requiredKey[elementName].map({ $0 == attributeDict["key"] }) ?? true else {
            return fail(parser, StoryboardParser.unsupported(elementName, line: line))
        }
        if let parent = stack.last {
            let repeats = StoryboardParser.repeatable.contains(elementName)
                || (StoryboardParser.viewKinds.contains(elementName) && parentName == "subviews")
            if !repeats {
                let id = elementName + "|" + (attributeDict["key"] ?? "")
                if !parent.seen.insert(id).inserted {
                    return fail(parser, XlessError(.ib, "unsupported element <\(elementName)> at line \(line) (duplicate; only one allowed)",
                                                   fix: StoryboardParser.unsupportedFix))
                }
            }
        }
        let path = stack.last.map { $0.path + [$0.children.count] } ?? []
        let node = XMLNode(name: elementName, attributes: attributeDict, line: line, path: path)
        if elementName == "string" { node.text = "" }
        stack.last?.children.append(node)
        if stack.isEmpty { root = node }
        stack.append(node)
    }

    private func fail(_ parser: XMLParser, _ e: XlessError) {
        failure = e
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if let node = stack.popLast(), StoryboardParser.viewKinds.contains(node.name) { viewDepth -= 1 }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text?.append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text?.append(String(decoding: CDATABlock, as: UTF8.self))
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        guard failure == nil else { return }
        failure = XlessError(.ib, "invalid storyboard XML at line \(parser.lineNumber): \(parseError.localizedDescription)",
                             fix: "open and re-save it in Xcode")
    }
}

private enum Lowerer {
    static func bad(_ msg: String, line: Int) -> XlessError {
        XlessError(.ib, "\(msg) at line \(line)", fix: "open and re-save it in Xcode")
    }

    static func unsupportedNumber(_ key: String, _ s: String, element: String, line: Int) -> XlessError {
        XlessError(.ib, "unsupported number \(key)=\"\(s)\" on <\(element)> at line \(line) (Xcode writes plain decimals)",
                   fix: "open and re-save it in Xcode")
    }

    static func document(_ n: XMLNode) throws -> IBDocument {
        guard n.name == "document" else { throw bad("root element is <\(n.name)>, expected <document>", line: n.line) }
        let a = n.attributes
        guard let initial = a["initialViewController"] else {
            throw bad("storyboard has no initialViewController", line: n.line)
        }
        let scenes = try (n.child(named: "scenes")?.children(named: "scene") ?? []).map(scene)
        guard !scenes.isEmpty else { throw bad("storyboard has no scenes", line: n.line) }
        var resources: [IBResource] = []
        var paths: [[Int]] = []
        for r in n.child(named: "resources")?.children ?? [] {
            switch r.name {
            case "systemColor":
                guard let name = r.attributes["name"], let c = r.child(named: "color") else { throw bad("malformed <systemColor>", line: r.line) }
                resources.append(.systemColor(name, try color(c))); paths.append(r.path)
            case "namedColor":
                guard let name = r.attributes["name"] else { throw bad("<namedColor> without name", line: r.line) }
                resources.append(.namedColor(name, try r.child(named: "color").map(color))); paths.append(r.path)
            case "image":
                guard let name = r.attributes["name"] else { throw bad("<image> without name", line: r.line) }
                resources.append(.image(name, width: r.attributes["width"], height: r.attributes["height"], catalog: r.attributes["catalog"])); paths.append(r.path)
            default:
                throw StoryboardParser.unsupported(r.name, line: r.line)
            }
        }
        return IBDocument(
            toolsVersion: a["toolsVersion"] ?? "", targetRuntime: a["targetRuntime"] ?? "",
            useAutolayout: a["useAutolayout"] == "YES", useSafeAreas: a["useSafeAreas"] == "YES",
            useTraitCollections: a["useTraitCollections"] == "YES",
            initialViewController: initial, scenes: scenes, resources: resources, resourcePaths: paths, attributes: a, raw: n.raw)
    }

    static func scene(_ n: XMLNode) throws -> IBScene {
        guard let id = n.attributes["sceneID"] else { throw bad("<scene> without sceneID", line: n.line) }
        guard let objects = n.child(named: "objects"), let vc = objects.child(named: "viewController") else {
            throw bad("scene \(id) has no viewController", line: n.line)
        }
        let placeholders = objects.children(named: "placeholder").map {
            IBPlaceholder(id: $0.attributes["id"] ?? "", attributes: $0.attributes, rawPath: $0.path)
        }
        return IBScene(sceneID: id, viewController: try viewController(vc), placeholders: placeholders, rawPath: n.path)
    }

    static func viewController(_ n: XMLNode) throws -> IBViewController {
        guard let id = n.attributes["id"] else { throw bad("<viewController> without id", line: n.line) }
        guard let v = n.child(named: "view") else { throw bad("viewController \(id) has no <view>", line: n.line) }
        return IBViewController(id: id, attributes: n.attributes, view: try view(v), rawPath: n.path)
    }

    static func view(_ n: XMLNode) throws -> IBView {
        guard let kind = IBView.Kind(rawValue: n.name) else { throw StoryboardParser.unsupported(n.name, line: n.line) }
        var frame: IBRect?
        for r in n.children(named: "rect") where r.attributes["key"] == "frame" {
            func d(_ k: String) throws -> Double? {
                guard let s = r.attributes[k] else { return nil }
                guard let v = XcodeNumber.parse(s) else { throw unsupportedNumber(k, s, element: "rect", line: r.line) }
                return v
            }
            guard let x = try d("x"), let y = try d("y"), let w = try d("width"), let h = try d("height") else {
                throw bad("malformed <rect>", line: r.line)
            }
            frame = IBRect(x: x, y: y, width: w, height: h)
        }
        var safeArea: IBLayoutGuide?
        if let g = n.children(named: "viewLayoutGuide").first(where: { $0.attributes["key"] == "safeArea" }) {
            safeArea = IBLayoutGuide(id: g.attributes["id"] ?? "", key: "safeArea", attributes: g.attributes, rawPath: g.path)
        }
        var colors: [String: IBColor] = [:]
        for c in n.children(named: "color") {
            guard let k = c.attributes["key"] else { throw bad("<color> without key", line: c.line) }
            colors[k] = try color(c)
        }
        let subviews = try (n.child(named: "subviews")?.children ?? []).map(view)
        let constraints = (n.child(named: "constraints")?.children(named: "constraint") ?? []).map {
            IBConstraint(id: $0.attributes["id"] ?? "", attributes: $0.attributes, line: $0.line, rawPath: $0.path)
        }
        var text: String?
        if kind == .label {
            text = n.attributes["text"]
            if let s = n.child(named: "string") {
                guard text == nil else { throw bad("label has both a text attribute and <string key=\"text\">", line: s.line) }
                text = s.text ?? ""
            }
        }
        var image: IBImageReference?
        if kind == .imageView {
            if let name = n.attributes["image"] { image = IBImageReference(name: name, catalog: n.attributes["catalog"]) }
            if let r = n.child(named: "imageReference") {
                guard image == nil else { throw bad("image view has both an image attribute and <imageReference key=\"image\">", line: r.line) }
                guard let name = r.attributes["image"] else { throw bad("<imageReference> without image", line: r.line) }
                image = IBImageReference(name: name, catalog: r.attributes["catalog"])
            }
        }
        return IBView(
            kind: kind, id: n.attributes["id"] ?? "", key: n.attributes["key"], attributes: n.attributes,
            frame: frame, autoresizingMask: n.child(named: "autoresizingMask")?.attributes, safeArea: safeArea,
            colors: colors, fontDescription: n.child(named: "fontDescription")?.attributes, text: text, image: image,
            subviews: subviews, constraints: constraints,
            nilKeys: Set(n.children(named: "nil").compactMap { $0.attributes["key"] }),
            accessibility: n.child(named: "accessibility").map {
                IBAccessibility(attributes: $0.attributes, traits: $0.child(named: "accessibilityTraits")?.attributes, line: $0.line)
            },
            line: n.line, rawPath: n.path)
    }

    static func color(_ n: XMLNode) throws -> IBColor {
        let a = n.attributes
        func invalid(_ why: String) -> XlessError {
            XlessError(.ib, "invalid color (\(why)) at line \(n.line)", fix: "open and re-save it in Xcode")
        }
        func num(_ k: String) throws -> Double? {
            guard let s = a[k] else { return nil }
            guard let v = XcodeNumber.parse(s, exponent: true) else { throw unsupportedNumber(k, s, element: "color", line: n.line) }
            return v
        }
        let components = ["red", "green", "blue", "white", "alpha"].filter { a[$0] != nil }
        if let form = ["systemColor", "name"].first(where: { a[$0] != nil }), let c = components.first {
            throw XlessError(.ib, "unsupported color with both \(form) and \(c) at line \(n.line)", fix: StoryboardParser.unsupportedFix)
        }
        let value: IBColor.Value
        if let s = a["systemColor"] {
            value = .system(s)
        } else if let s = a["name"] {
            value = .named(s)
        } else if ["red", "green", "blue", "white", "alpha"].contains(where: { a[$0] != nil }) {
            let (r, g, b, w, al) = (try num("red"), try num("green"), try num("blue"), try num("white"), try num("alpha"))
            if let w {
                guard r == nil, g == nil, b == nil else { throw invalid("white mixed with red/green/blue") }
                value = .white(w, al ?? 1, a["colorSpace"], a["customColorSpace"])
            } else {
                guard let r, let g, let b else { throw invalid("missing color components") }
                value = .rgba(r, g, b, al ?? 1, a["colorSpace"], a["customColorSpace"])
            }
        } else {
            value = .other
        }
        return IBColor(value: value, rawAttributes: a, rawPath: n.path)
    }
}
