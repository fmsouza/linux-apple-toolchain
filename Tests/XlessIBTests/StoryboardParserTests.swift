import Foundation
import Testing
import XlessCore
@testable import XlessIB

private func corpusText(_ name: String) throws -> String {
    try String(contentsOf: corpusRoot.appendingPathComponent(name), encoding: .utf8)
}

private func stripLines(_ v: IBView) -> IBView {
    var v = v
    v.line = 0
    v.subviews = v.subviews.map(stripLines)
    v.constraints = v.constraints.map { var c = $0; c.line = 0; return c }
    return v
}

private func stripLines(_ e: IBRawElement) -> IBRawElement {
    var e = e
    e.line = 0
    e.children = e.children.map(stripLines)
    return e
}

private func stripLines(_ d: IBDocument) -> IBDocument {
    var d = d
    d.raw = stripLines(d.raw)
    d.scenes = d.scenes.map { s in
        var s = s
        s.viewController.view = stripLines(s.viewController.view)
        return s
    }
    return d
}

@Test func parsesRealTauriAppStoryboard() throws {
    let doc = try StoryboardParser.parse(url: corpusRoot.appendingPathComponent("real-tauri-app.storyboard"))
    #expect(doc.scenes.count == 1)
    let scene = doc.scenes[0]
    #expect(doc.initialViewController == "Y6W-OH-hqX")
    #expect(scene.viewController.id == "Y6W-OH-hqX")
    #expect(scene.placeholders.count == 1)
    let view = scene.viewController.view
    #expect(view.id == "5EZ-qb-Rvc")
    #expect(view.kind == .view)
    #expect(view.key == "view")
    #expect(view.safeArea?.id == "vDu-zF-Fre")
    #expect(view.frame == IBRect(x: 0, y: 0, width: 414, height: 896))
    #expect(view.autoresizingMask?["widthSizable"] == "YES")
    #expect(view.colors["backgroundColor"]?.value == .system("systemBackgroundColor"))
    #expect(doc.toolsVersion == "17150")
    #expect(doc.targetRuntime == "iOS.CocoaTouch")
    #expect(doc.useAutolayout && doc.useSafeAreas && doc.useTraitCollections)
    #expect(doc.resources.count == 1)
    guard case let .systemColor(name, color) = doc.resources[0] else { Issue.record("not a system color"); return }
    #expect(name == "systemBackgroundColor")
    #expect(color.value == .white(1, 1, "custom", "genericGamma22GrayColorSpace"))
    #expect(color.rawAttributes["white"] == "1")
}

@Test func parsesXcodeTemplateStoryboard() throws {
    let doc = try StoryboardParser.parse(url: corpusRoot.appendingPathComponent("xcode-template.storyboard"))
    #expect(doc.initialViewController == "01J-lp-oVM")
    #expect(doc.attributes["launchScreen"] == "YES")
    let bg = doc.scenes[0].viewController.view.colors["backgroundColor"]
    #expect(bg?.value == .other)
    #expect(bg?.rawAttributes["xcode11CocoaTouchSystemColor"] == "systemBackgroundColor")
}

@Test func rejectsDisallowedElementWithLine() throws {
    let base = try corpusText("real-tauri-app.storyboard")
    let bad = base.replacingOccurrences(of: "</view>", with: "<subviews><button id=\"b1\"/></subviews></view>")
    let expectedLine = bad.components(separatedBy: "\n").firstIndex { $0.contains("<button") }! + 1
    do {
        _ = try StoryboardParser.parse(Data(bad.utf8))
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.stage == .ib)
        #expect(e.cause == "unsupported element <button> at line \(expectedLine)")
        #expect(e.fix.contains("launch-screen storyboards support"))
    }
}

@Test func rejectsNonLayoutGuideConnections() {
    let xml = """
    <document initialViewController="a"><scenes><scene sceneID="s"><objects>
    <viewController id="a"><connections><outlet property="x" destination="y"/></connections>
    <view id="v"/></viewController></objects></scene></scenes></document>
    """
    #expect(throws: XlessError.self) { try StoryboardParser.parse(Data(xml.utf8)) }
    let ok = xml.replacingOccurrences(of: "<outlet property=\"x\" destination=\"y\"/>",
        with: "<layoutGuides><viewControllerLayoutGuide type=\"top\" id=\"t\"/></layoutGuides>")
    #expect(throws: Never.self) { try StoryboardParser.parse(Data(ok.utf8)) }
}

@Test func reportsMalformedXML() {
    do {
        _ = try StoryboardParser.parse(Data("<document><scenes></document>".utf8))
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.cause.hasPrefix("invalid storyboard XML at line 1"))
        #expect(e.fix == "open and re-save it in Xcode")
    } catch { Issue.record("wrong error \(error)") }
}

@Test func formattingDoesNotChangeModel() throws {
    let plain = """
    <?xml version="1.0" encoding="UTF-8"?>
    <document toolsVersion="17150" targetRuntime="iOS.CocoaTouch" useAutolayout="YES" initialViewController="vc1">
        <scenes>
            <scene sceneID="s1">
                <objects>
                    <viewController id="vc1" sceneMemberID="viewController">
                        <view key="view" contentMode="scaleToFill" id="v1">
                            <rect key="frame" x="0.0" y="0.0" width="414" height="896"/>
                            <subviews>
                                <label opaque="NO" text="A" id="l1">
                                    <rect key="frame" x="1" y="2" width="3" height="4"/>
                                </label>
                            </subviews>
                            <constraints>
                                <constraint firstItem="l1" firstAttribute="top" secondItem="v1" secondAttribute="top" constant="8" id="c1"/>
                            </constraints>
                        </view>
                    </viewController>
                </objects>
            </scene>
        </scenes>
    </document>

    """
    let messy = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!-- leading comment -->
    <document initialViewController="vc1" useAutolayout="YES" targetRuntime="iOS.CocoaTouch" toolsVersion="17150">
        <!-- scenes -->
        <scenes>
            <scene sceneID="s1">
                <objects>
                    <viewController sceneMemberID="viewController" id="vc1">
                        <view id="v1" contentMode="scaleToFill" key="view">
                            <rect height="896" width="414" y="0.0" x="0.0" key="frame"/>
                            <subviews>
                                <!-- the label -->
                                <label id="l1" text="&#x41;" opaque="NO">
                                    <rect height="4" width="3" y="2" x="1" key="frame"/>
                                </label>
                            </subviews>
                            <constraints>
                                <constraint id="c1" constant="8" secondAttribute="top" secondItem="v1" firstAttribute="top" firstItem="l1"/>
                            </constraints>
                        </view>
                    </viewController>
                </objects>
            </scene>
        </scenes>
    </document>

    """.replacingOccurrences(of: "\n", with: "\r\n")
    let a = try StoryboardParser.parse(Data(plain.utf8))
    let b = try StoryboardParser.parse(Data(messy.utf8))
    #expect(stripLines(a) == stripLines(b))
    #expect(a.scenes[0].viewController.view.subviews[0].attributes["text"] == "A")
    #expect(a.scenes[0].viewController.view.constraints[0].attributes["constant"] == "8")
}

@Test func labelTextIsParsedExactly() throws {
    let text = "Olá 🚢 مرحبا"
    let xml = """
    <document initialViewController="vc1"><scenes><scene sceneID="s1"><objects>
    <viewController id="vc1"><view key="view" id="v1"><subviews>
    <label text="\(text)" id="l1"/>
    </subviews></view></viewController></objects></scene></scenes></document>
    """
    let doc = try StoryboardParser.parse(Data(xml.utf8))
    let label = doc.scenes[0].viewController.view.subviews[0]
    #expect(label.kind == .label)
    #expect(label.attributes["text"] == text)
}

// MARK: - Review fixes

private func sb(_ viewBody: String, vcExtra: String = "", docExtra: String = "") -> String {
    """
    <document initialViewController="vc1">\(docExtra)<scenes><scene sceneID="s1"><objects>
    <viewController id="vc1">\(vcExtra)<view key="view" id="v1">
    \(viewBody)
    </view></viewController></objects></scene></scenes></document>
    """
}

private func expectUnsupported(_ xml: String, _ element: String, line: Int, sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        _ = try StoryboardParser.parse(Data(xml.utf8))
        Issue.record("expected throw", sourceLocation: sourceLocation)
    } catch let e as XlessError {
        #expect(e.stage == .ib, sourceLocation: sourceLocation)
        #expect(e.cause.hasPrefix("unsupported element <\(element)> at line \(line)"), "\(e.cause)", sourceLocation: sourceLocation)
    } catch { Issue.record("wrong error \(error)", sourceLocation: sourceLocation) }
}

private func expectIBError(_ xml: String, contains: String, line: Int, sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        _ = try StoryboardParser.parse(Data(xml.utf8))
        Issue.record("expected throw", sourceLocation: sourceLocation)
    } catch let e as XlessError {
        #expect(e.cause.contains(contains) && e.cause.contains("line \(line)"), "\(e.cause)", sourceLocation: sourceLocation)
    } catch { Issue.record("wrong error \(error)", sourceLocation: sourceLocation) }
}

@Test func labelInsideConstraintsIsRejected() {
    let xml = sb("<constraints>\n<label id=\"x\"/>\n</constraints>")
    let line = xml.components(separatedBy: "\n").firstIndex { $0.contains("<label") }! + 1
    expectUnsupported(xml, "label", line: line)
}

@Test func misplacedStructureIsRejected() {
    // scene directly under document
    expectUnsupported("<document initialViewController=\"a\">\n<scene sceneID=\"s\"/></document>", "scene", line: 2)
    // second subviews
    expectUnsupported(sb("<subviews/>\n<subviews/>"), "subviews", line: 4)
    // second viewController
    let two = """
    <document initialViewController="a"><scenes><scene sceneID="s"><objects>
    <viewController id="a"><view id="v"/></viewController>
    <viewController id="b"><view id="w"/></viewController>
    </objects></scene></scenes></document>
    """
    expectUnsupported(two, "viewController", line: 3)
    // layoutGuides must hold only viewControllerLayoutGuide
    expectUnsupported(sb("", vcExtra: "<connections>\n<layoutGuides>\n<label id=\"q\"/></layoutGuides></connections>"), "label", line: 4)
}

@Test func connectionsRejectsAllowedButMisplacedChild() {
    let xml = sb("", vcExtra: "<connections>\n<view id=\"q\"/></connections>")
    expectUnsupported(xml, "view", line: 3)
}

@Test func duplicateSingletonsAreRejected() {
    expectIBError(sb("<fontDescription key=\"fontDescription\" type=\"system\"/>\n<fontDescription key=\"fontDescription\" type=\"system\"/>"), contains: "<fontDescription>", line: 4)
    expectIBError(sb("<rect key=\"frame\" x=\"0\" y=\"0\" width=\"1\" height=\"1\"/>\n<rect key=\"frame\" x=\"0\" y=\"0\" width=\"1\" height=\"1\"/>"), contains: "<rect>", line: 4)
    expectIBError(sb("<color key=\"backgroundColor\" systemColor=\"a\"/>\n<color key=\"backgroundColor\" systemColor=\"b\"/>"), contains: "<color>", line: 4)
}

@Test func nilKeysAreRecorded() throws {
    let doc = try StoryboardParser.parse(Data(sb("<nil key=\"highlightedColor\"/><nil key=\"textColor\"/>").utf8))
    #expect(doc.scenes[0].viewController.view.nilKeys == ["highlightedColor", "textColor"])
}

@Test func deviceElementParsesAndIsKeptRaw() throws {
    let xml = sb("", docExtra: "<device id=\"retina6_1\" orientation=\"portrait\" appearance=\"light\"><adaptation id=\"fullscreen\"/></device>")
    let doc = try StoryboardParser.parse(Data(xml.utf8))
    let device = doc.raw.children.first { $0.name == "device" }
    #expect(device?.attributes["orientation"] == "portrait")
    #expect(device?.children.first?.name == "adaptation")
}

@Test func multiLineStartTagReportsStartLine() {
    let xml = """
    <document initialViewController="a"><scenes><scene sceneID="s"><objects>
    <viewController id="a"><view id="v">
    <subviews><button
        id="b1"
        title=">"
        />
    </subviews></view></viewController></objects></scene></scenes></document>
    """
    expectUnsupported(xml, "button", line: 3)
}

@Test func linesSurviveCommentsCDATAAndCRLF() {
    let xml = "<document initialViewController=\"a\">\r\n<!-- <label/>\r\n\r\n -->\r\n<scenes><scene sceneID=\"s\"><objects><viewController id=\"a\"><view id=\"v\"><subviews>\r\n  <button/></subviews></view></viewController></objects></scene></scenes></document>"
    expectUnsupported(xml, "button", line: 6)
}

@Test func rawTreeIsLosslessAndReachableFromTypedNodes() throws {
    let doc = try StoryboardParser.parse(url: corpusRoot.appendingPathComponent("real-tauri-app.storyboard"))
    #expect(doc.raw.name == "document")
    #expect(doc.raw.attributes["colorMatched"] == "YES")
    let dep = doc.raw.children.first { $0.name == "dependencies" }
    #expect(dep?.children.first { $0.name == "capability" }?.attributes["minToolsVersion"] != nil)
    let scene = doc.element(at: doc.scenes[0].rawPath)
    #expect(scene?.name == "scene")
    #expect(scene?.children.first { $0.name == "point" } == nil)
    let t = try StoryboardParser.parse(url: corpusRoot.appendingPathComponent("xcode-template.storyboard"))
    #expect(t.element(at: t.scenes[0].rawPath)?.children.first { $0.name == "point" }?.attributes["x"] == "53")
    let view = doc.scenes[0].viewController.view
    #expect(doc.element(at: view.rawPath)?.attributes["id"] == "5EZ-qb-Rvc")
    #expect(doc.element(at: view.colors["backgroundColor"]!.rawPath)?.attributes["systemColor"] == "systemBackgroundColor")
    #expect(doc.element(at: doc.resourcePaths[0])?.name == "systemColor")
    #expect(doc.element(at: doc.resourcePaths[0])?.attributes["name"] == "systemBackgroundColor")
    #expect(doc.element(at: doc.scenes[0].placeholders[0].rawPath)?.attributes["customClass"] == "UIResponder")
}

@Test func malformedColorsAreRejected() {
    let bad = [
        "red=\"1\" green=\"0\"",
        "white=\"1\" red=\"1\"",
        "alpha=\"1\"",
    ]
    for attrs in bad {
        expectIBError(sb("\n<color key=\"backgroundColor\" \(attrs) colorSpace=\"sRGB\"/>"), contains: "invalid color", line: 4)
    }
    let badNumbers = [
        "red=\"1\" green=\"0\" blue=\"x\" alpha=\"1\"",
        "red=\"1\" green=\"0\" blue=\"0\" alpha=\"nan\"",
        "red=\"inf\" green=\"0\" blue=\"0\" alpha=\"1\"",
        "white=\"nan\" alpha=\"1\"",
        "white=\"1\" alpha=\"oops\"",
    ]
    for attrs in badNumbers {
        expectIBError(sb("\n<color key=\"backgroundColor\" \(attrs) colorSpace=\"sRGB\"/>"), contains: "unsupported number", line: 4)
    }
    let ok = try? StoryboardParser.parse(Data(sb("<color key=\"backgroundColor\" cocoaTouchSystemColor=\"whiteColor\"/>").utf8))
    #expect(ok?.scenes[0].viewController.view.colors["backgroundColor"]?.value == .other)
}

@Test func nonFiniteRectIsRejected() {
    expectIBError(sb("<rect key=\"frame\" x=\"nan\" y=\"0\" width=\"1\" height=\"1\"/>"), contains: "<rect>", line: 3)
    expectIBError(sb("<rect key=\"frame\" x=\"0\" y=\"inf\" width=\"1\" height=\"1\"/>"), contains: "<rect>", line: 3)
}

// MARK: - R8: <string key="text"> and <imageReference key="image">

private func firstSubview(_ xml: String) throws -> (IBDocument, IBView) {
    let doc = try StoryboardParser.parse(Data(xml.utf8))
    return (doc, doc.scenes[0].viewController.view.subviews[0])
}

@Test func labelTextElementMapsLikeTextAttribute() throws {
    // Xcode writes label text containing a newline as <string key="text"> (corpus case label-multiline-text).
    let (doc, label) = try firstSubview(sb("<subviews><label id=\"l1\">\n<string key=\"text\">Line one\nLine  two &amp; \"3\"</string>\n</label></subviews>"))
    #expect(label.text == "Line one\nLine  two & \"3\"")
    let raw = try #require(doc.element(at: label.rawPath)?.children.first { $0.name == "string" })
    #expect(raw.attributes == ["key": "text"])
    #expect(raw.text == "Line one\nLine  two & \"3\"")
    let (_, attrLabel) = try firstSubview(sb("<subviews><label text=\"Plain\" id=\"l1\"/></subviews>"))
    #expect(attrLabel.text == "Plain")
    let (_, empty) = try firstSubview(sb("<subviews><label id=\"l1\"><string key=\"text\"></string></label></subviews>"))
    #expect(empty.text == "")
}

@Test func imageReferenceMapsLikeImageAttribute() throws {
    // Xcode's image-reference form (corpus case image-reference; Xcode's Safari Extension App LaunchScreen template).
    let (doc, iv) = try firstSubview(sb("<subviews><imageView id=\"i1\"><imageReference key=\"image\" image=\"Logo\"/></imageView></subviews>"))
    #expect(iv.image == IBImageReference(name: "Logo", catalog: nil))
    #expect(doc.element(at: iv.rawPath)?.children.first?.attributes == ["key": "image", "image": "Logo"])
    let (_, sym) = try firstSubview(sb("<subviews><imageView id=\"i1\"><imageReference key=\"image\" image=\"star.fill\" catalog=\"system\"/></imageView></subviews>"))
    #expect(sym.image == IBImageReference(name: "star.fill", catalog: "system"))
    let (_, attr) = try firstSubview(sb("<subviews><imageView image=\"star.fill\" catalog=\"system\" id=\"i1\"/></subviews>"))
    #expect(attr.image == IBImageReference(name: "star.fill", catalog: "system"))
    let (_, none) = try firstSubview(sb("<subviews><imageView id=\"i1\"/></subviews>"))
    #expect(none.image == nil)
}

@Test func textAndImageElementsAreRestrictedToTheirKeyAndParent() {
    expectUnsupported(sb("<subviews><label id=\"l1\">\n<string key=\"title\">x</string></label></subviews>"), "string", line: 4)
    expectUnsupported(sb("<subviews><imageView id=\"i1\">\n<string key=\"text\">x</string></imageView></subviews>"), "string", line: 4)
    expectUnsupported(sb("<subviews><label id=\"l1\">\n<imageReference key=\"image\" image=\"a\"/></label></subviews>"), "imageReference", line: 4)
    expectUnsupported(sb("<subviews><imageView id=\"i1\">\n<imageReference key=\"highlightedImage\" image=\"a\"/></imageView></subviews>"), "imageReference", line: 4)
    expectUnsupported(sb("<subviews><label id=\"l1\"><string key=\"text\">\n<b/></string></label></subviews>"), "b", line: 4)
    expectIBError(sb("<subviews><label text=\"a\" id=\"l1\">\n<string key=\"text\">b</string></label></subviews>"), contains: "text", line: 4)
    expectIBError(sb("<subviews><imageView image=\"a\" id=\"i1\">\n<imageReference key=\"image\" image=\"b\"/></imageView></subviews>"), contains: "image", line: 4)
}

/// `levels` views nested inside the root view (one per line, starting on line 4), as `<subviews><view>` pairs.
private func nested(_ levels: Int) -> String {
    var s = ""
    for i in 0..<levels { s += "<subviews><view id=\"n\(i)\">\n" }
    for _ in 0..<levels { s += "</view></subviews>" }
    return sb("\n" + s)
}

/// Final review I4: deep nesting is refused before any recursion (no stack overflow or quadratic memory), at the
/// line of the first view below level 32 (the root view is level 1; `nesting-32-levels` proves level 32).
@Test func refusesViewsNestedDeeperThan32Levels() throws {
    _ = try StoryboardParser.parse(Data(nested(31).utf8))
    expectIBError(nested(32), contains: "unsupported: views nested deeper than 32 levels", line: 35)
    let start = Date()
    expectIBError(nested(20_000), contains: "unsupported: views nested deeper than 32 levels", line: 35)
    #expect(Date().timeIntervalSince(start) < 10)
}

/// Storyboards larger than 4 MiB are refused before parsing (launch screens are a few KB).
@Test func refusesOversizedStoryboards() throws {
    let big = sb("<!--" + String(repeating: "x", count: 4 << 20) + "-->")
    let e = try #require(throws: XlessError.self) { try StoryboardParser.parse(Data(big.utf8)) }
    #expect(e.stage == .ib)
    #expect(e.cause.hasPrefix("unsupported: storyboard of \(big.utf8.count) bytes"))
}
