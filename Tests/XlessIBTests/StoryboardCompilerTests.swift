import Testing
import Foundation
import XlessCore
@testable import XlessIB

/// `core-safearea` with `replace` applied, compiled with `universal-16`.
private func compileVariant(of name: String = "core-safearea", _ replace: [(String, String)]) throws -> IBCompileResult {
    var xml = try String(contentsOf: CorpusCase(name: name).storyboard, encoding: .utf8)
    for (a, b) in replace {
        #expect(xml.contains(a), "variant anchor missing: \(a)")
        xml = xml.replacingOccurrences(of: a, with: b)
    }
    let doc = try StoryboardParser.parse(Data(xml.utf8))
    return try StoryboardCompiler.compile(doc, options: .flagset(named: "universal-16", root: corpusRoot))
}

private func refusal(of name: String = "core-safearea", _ replace: [(String, String)]) throws -> XlessError {
    try #require(throws: XlessError.self) { try compileVariant(of: name, replace) }
}

@Test func flagsetOptionsComeFromFlagsetsJSON() throws {
    let u16 = try IBCompileOptions.flagset(named: "universal-16", root: corpusRoot)
    #expect(u16 == IBCompileOptions(targetDevices: ["iphone", "ipad"], minimumDeploymentTarget: "16.0"))
    #expect(u16.targetDevices == ["ipad", "iphone"])
    #expect(try IBCompileOptions.flagset(named: "iphone-16", root: corpusRoot).targetDevices == ["iphone"])
    #expect(throws: XlessError.self) { try IBCompileOptions.flagset(named: "universal-13", root: corpusRoot) }
}

@Test func compileByURLWritesTheThreeFiles() throws {
    let r = try StoryboardCompiler.compile(url: CorpusCase(name: "xcode-template").storyboard,
                                           options: IBCompileOptions(targetDevices: ["iphone"], minimumDeploymentTarget: "16.0"))
    #expect(r.files.keys.sorted() == ["01J-lp-oVM-view-Ze5-6b-2t3.nib", "Info.plist", "UIViewController-01J-lp-oVM.nib"])
    #expect(r.warnings.isEmpty)
}

@Test func refusesUnverifiedOptions() throws {
    let doc = try StoryboardParser.parse(url: CorpusCase(name: "core-safearea").storyboard)
    for (devices, target) in [(["ipad"], "16.0"), (["iphone"], "13.0"), (["iphone"], "28.0"), (["iphone"], "sixteen")] {
        #expect(throws: XlessError.self, "\(devices) \(target)") {
            try StoryboardCompiler.compile(doc, options: IBCompileOptions(targetDevices: devices, minimumDeploymentTarget: target))
        }
    }
    _ = try StoryboardCompiler.compile(doc, options: IBCompileOptions(targetDevices: ["iphone"], minimumDeploymentTarget: "27.4"))
}

@Test func refusesUnknownDeviceAsOpenQuestion() throws {
    let e = try refusal([(#"<device id="retina6_12""#, #"<device id="retina6_72""#)])
    #expect(e.cause == #"unsupported: device id "retina6_72" (its size in ibtool is unknown) at line 3 (see docs/research/nib-encoding.md#open-questions)"#)
}

@Test func refusesAttributesTheRulesDoNotEncode() throws {
    let e = try refusal([(#"<view key="view" contentMode="scaleToFill""#, #"<view key="view" alpha="0.5" contentMode="scaleToFill""#)])
    #expect(e.cause == #"unsupported attribute alpha="0.5" on the root <view> at line 15"#)
    let vc = try refusal([(#"<viewController id="01J-lp-oVM""#, #"<viewController id="01J-lp-oVM" customClass="Mine""#)])
    #expect(vc.cause.hasPrefix(#"unsupported attribute customClass="Mine" on <viewController>"#))
}

@Test func refusesUnknownSystemColor() throws {
    let e = try refusal(of: "color-system-systemBlueColor", [(#"systemColor="systemBlueColor""#, #"systemColor="systemNeonColor""#)])
    #expect(e.cause.hasPrefix(#"unsupported system color "systemNeonColor""#))
}

@Test func refusesNamedColorWithNonSRGBResource() throws {
    let e = try refusal(of: "color-named-exists", [(#"red="0.20000000000000001" green="0.40000000000000002" blue="0.59999999999999998""#, #"white="0.5""#),
                                                   (#"customColorSpace="sRGB""#, #"customColorSpace="genericGamma22GrayColorSpace""#)])
    #expect(e.cause.hasPrefix(#"unsupported named color "Brand" whose resource is not an sRGB color"#))
}

// MARK: R9 review: inputs accepted without a golden behind them

private let rootView = #"<view key="view" contentMode="scaleToFill" id="Ze5-6b-2t3">"#

@Test func refusesRootViewAttributesWithoutGoldens() throws {
    for (attr, expected) in [(#"opaque="NO""#, #"unsupported attribute opaque="NO" on the root <view>"#),
                             (#"clipsSubviews="YES""#, #"unsupported attribute clipsSubviews="YES" on the root <view>"#),
                             (#"userInteractionEnabled="NO""#, #"unsupported attribute userInteractionEnabled="NO" on the root <view>"#)] {
        let e = try refusal([(rootView, rootView.replacingOccurrences(of: " id=", with: " \(attr) id="))])
        #expect(e.cause.hasPrefix(expected), "\(e)")
    }
    let mode = try refusal([(rootView, rootView.replacingOccurrences(of: "scaleToFill", with: "center"))])
    #expect(mode.cause.hasPrefix(#"unsupported contentMode="center" on the root <view>"#), "\(mode)")
}

@Test func refusesDocumentAttributesOutsideTheCorpus() throws {
    let cases: [(String, String, String)] = [
        (#"useAutolayout="YES""#, #"useAutolayout="NO""#, #"unsupported <document> useAutolayout="NO""#),
        (#" colorMatched="YES""#, "", "unsupported <document> without colorMatched"),
        (#"targetRuntime="iOS.CocoaTouch""#, #"targetRuntime="AppleTV""#, #"unsupported <document> targetRuntime="AppleTV""#),
        (#"launchScreen="YES""#, #"launchScreen="NO""#, #"unsupported <document> launchScreen="NO""#),
        (#"version="3.0""#, #"version="2.0""#, #"unsupported <document> version="2.0""#),
        (#"propertyAccessControl="none""#, #"propertyAccessControl="all""#, #"unsupported <document> propertyAccessControl="all""#),
        (#"toolsVersion="23727""#, #"toolsVersion="new""#, #"unsupported <document> toolsVersion="new""#),
        (#"useTraitCollections="YES""#, #"useTraitCollections="NO""#, #"unsupported <document> useTraitCollections="NO""#),
        (#"useSafeAreas="YES""#, #"useSafeAreas="yes""#, #"unsupported <document> useSafeAreas="yes""#),
        (#"colorMatched="YES""#, #"colorMatched="YES" customObjectInstantitationMethod="direct""#,
         #"unsupported attribute customObjectInstantitationMethod="direct" on <document>"#),
    ]
    for (from, to, expected) in cases {
        let e = try refusal([(from, to)])
        #expect(e.cause.hasPrefix(expected), "\(e)")
    }
    // seen in the corpus: other tools versions (real-tauri-app 17150, xcode-template 13122.16), launchScreen absent
    _ = try compileVariant([(#"toolsVersion="23727""#, #"toolsVersion="13122.16""#), (#" launchScreen="YES""#, "")])
}

@Test func refusesRectsOtherThanFrame() throws {
    let e = try refusal([(#"<rect key="frame" x="0.0" y="0.0" width="393" height="852"/>"#,
                          #"<rect key="frame" x="0.0" y="0.0" width="393" height="852"/><rect key="bounds" x="0.0" y="0.0" width="1" height="1"/>"#)])
    #expect(e.cause.hasPrefix(#"unsupported <rect key="bounds">"#), "\(e)")
}

@Test func refusesDeviceAppearancesAndAdaptationsOutsideTheCorpus() throws {
    let e = try refusal([(#"appearance="light""#, #"appearance="unspecified""#)])
    #expect(e.cause.hasPrefix(#"unsupported device appearance "unspecified""#), "\(e)")
    let a = try refusal(of: "device-adaptation-fullscreen", [(#"<adaptation id="fullscreen"/>"#, #"<adaptation id="splitview"/>"#)])
    #expect(a.cause.hasPrefix(#"unsupported <adaptation id="splitview">"#), "\(a)")
}

@Test func refusesLegacyLayoutGuidesInSafeAreaMode() throws {
    let guides = #"<layoutGuides><viewControllerLayoutGuide type="top" id="Llm-lL-Icb"/></layoutGuides>"#
    let e = try refusal([(#"<viewController id="01J-lp-oVM" sceneMemberID="viewController">"#,
                          #"<viewController id="01J-lp-oVM" sceneMemberID="viewController">"# + guides)])
    #expect(e.cause.hasPrefix("unsupported <layoutGuides> with safe area layout guides"), "\(e)")
}

@Test func refusesColorComponentsOutsideTheUnitRangeOrWithoutAlpha() throws {
    let base = #"red="0.25" green="0.5" blue="0.75" alpha="0.5""#
    for (to, expected) in [(#"red="1.5" green="0.5" blue="0.75" alpha="0.5""#, #"unsupported color component red="1.5""#),
                           (#"red="0.25" green="-0.1" blue="0.75" alpha="0.5""#, #"unsupported color component green="-0.1""#),
                           (#"red="0.25" green="0.5" blue="0.75" alpha="2""#, #"unsupported color component alpha="2""#),
                           (#"red="0.25" green="0.5" blue="0.75""#, "unsupported color without alpha")] {
        let e = try refusal(of: "color-srgb-alpha", [(base, to)])
        #expect(e.cause.hasPrefix(expected), "\(e)")
    }
    let w = try refusal(of: "color-white-gray", [(#"alpha="1" colorSpace"#, #"colorSpace"#)])
    #expect(w.cause.hasPrefix("unsupported color without alpha"), "\(w)")
}

@Test func refusesXcode11SystemColorsOtherThanTheTemplatePair() throws {
    let e = try refusal(of: "xcode-template", [(#"xcode11CocoaTouchSystemColor="systemBackgroundColor""#, #"xcode11CocoaTouchSystemColor="systemGroupedBackgroundColor""#)])
    #expect(e.cause.hasPrefix(#"unsupported color cocoaTouchSystemColor="whiteColor" xcode11CocoaTouchSystemColor="systemGroupedBackgroundColor""#), "\(e)")
    let f = try refusal(of: "xcode-template", [(#"cocoaTouchSystemColor="whiteColor""#, #"cocoaTouchSystemColor="clearColor""#)])
    #expect(f.cause.hasPrefix("unsupported color "), "\(f)")
}

@Test func refusesBooleansOtherThanYESAndNO() throws {
    let sub = #"<view contentMode="scaleToFill" fixedFrame="YES""#
    for (to, expected) in [(#"<view opaque="no" contentMode="scaleToFill" fixedFrame="YES""#, #"unsupported opaque="no" (expected YES or NO)"#),
                           (#"<view contentMode="scaleToFill" fixedFrame="true""#, #"unsupported fixedFrame="true" (expected YES or NO)"#)] {
        let e = try refusal(of: "view-plain-default", [(sub, to)])
        #expect(e.cause.hasPrefix(expected), "\(e)")
    }
    let m = try refusal(of: "view-plain-default", [(#"flexibleMaxX="YES""#, #"flexibleMaxX="1""#)])
    #expect(m.cause.hasPrefix(#"unsupported autoresizingMask flexibleMaxX="1""#), "\(m)")
}

// MARK: R9 (Task 7): content modes, hugging priorities and image-view inputs without a golden behind them

private let imageTag = #"<imageView clipsSubviews="YES" userInteractionEnabled="NO" contentMode="scaleAspectFit""#

@Test func refusesUnknownContentModes() throws {
    let v = try refusal(of: "view-plain-default", [(#"contentMode="scaleToFill" fixedFrame"#, #"contentMode="bogusMode" fixedFrame"#)])
    #expect(v.cause.hasPrefix(#"unsupported contentMode="bogusMode" on <view>"#), "\(v)")
    // the lower-case spelling ibtool also maps to scaleToFill (Xcode writes "TopLeft")
    let i = try refusal(of: "image-catalog-center", [(#"contentMode="center""#, #"contentMode="topLeft""#)])
    #expect(i.cause.hasPrefix(#"unsupported contentMode="topLeft" on <imageView>"#), "\(i)")
    let missing = try refusal(of: "image-catalog-center", [(#" contentMode="center""#, "")])
    #expect(missing.cause.hasPrefix("unsupported <imageView> without contentMode"), "\(missing)")
}

@Test func refusesHuggingPrioritiesOutsideOneToAThousand() throws {
    for bad in ["0", "1001", "250.5", "0250", "high"] {
        let e = try refusal(of: "image-hugging-custom", [(#"horizontalHuggingPriority="300""#, #"horizontalHuggingPriority="\#(bad)""#)])
        #expect(e.cause.hasPrefix(#"unsupported horizontalHuggingPriority="\#(bad)" (supported: whole numbers 1–1000)"#), "\(e)")
    }
    let v = try refusal(of: "view-hugging-custom", [(#"verticalHuggingPriority="200""#, #"verticalHuggingPriority="-1""#)])
    #expect(v.cause.hasPrefix(#"unsupported verticalHuggingPriority="-1""#), "\(v)")
}

@Test func refusesImageViewInputsWithoutGoldens() throws {
    let cases: [(String, String, String)] = [
        (imageTag, imageTag + #" highlightedImage="Logo""#, #"unsupported attribute highlightedImage="Logo" on <imageView>"#),
        (imageTag, imageTag + #" adjustsImageSizeForAccessibilityContentSizeCategory="YES""#,
         #"unsupported attribute adjustsImageSizeForAccessibilityContentSizeCategory="YES" on <imageView>"#),
        (imageTag, imageTag + #" key="logo""#, #"unsupported attribute key="logo" on <imageView>"#),
        (imageTag, imageTag + #" horizontalCompressionResistancePriority="751""#,
         #"unsupported attribute horizontalCompressionResistancePriority="751" on <imageView>"#),
        (#"image="Logo" translates"#, #"image="Logo" catalog="mine" translates"#, #"unsupported image catalog="mine""#),
        (#"image="Logo" translates"#, #"image="" translates"#, "unsupported image view with an empty image name"),
        (#"image="Logo" translates"#, #"catalog="system" translates"#,
         #"unsupported attribute catalog="system" on <imageView> without an image attribute"#),
        (#"<rect key="frame" x="146.5""#, #"<color key="highlightedColor" systemColor="systemBlueColor"/><rect key="frame" x="146.5""#,
         #"unsupported color key "highlightedColor" on <imageView>"#),
        (#"<rect key="frame" x="146.5""#, #"<nil key="highlightedImage"/><rect key="frame" x="146.5""#,
         #"unsupported <nil key="highlightedImage"> on <imageView>"#),
        (#"<rect key="frame" x="146.5" y="376" width="100" height="100"/>"#,
         #"<rect key="frame" x="146.5" y="376" width="100" height="100"/><subviews><view contentMode="scaleToFill" id="sub-vw-001"><rect key="frame" x="0.0" y="0.0" width="1" height="1"/></view></subviews>"#,
         "unsupported subview inside an <imageView>"),
    ]
    for (from, to, expected) in cases {
        let e = try refusal(of: "image-catalog-scaleAspectFit", [(from, to)])
        #expect(e.cause.hasPrefix(expected), "\(e)")
    }
    let sub = try refusal(of: "view-plain-default", [(#"<view contentMode="scaleToFill" fixedFrame"#, #"<view key="band" contentMode="scaleToFill" fixedFrame"#)])
    #expect(sub.cause.hasPrefix(#"unsupported attribute key="band" on <view>"#), "\(sub)")
    let ref = try refusal(of: "image-reference", [(#"<imageReference key="image" image="Logo"/>"#, #"<imageReference key="image" image="Logo" renderingMode="template"/>"#)])
    #expect(ref.cause.hasPrefix(#"unsupported attribute renderingMode="template" on <imageReference>"#), "\(ref)")
    let outer = try refusal(of: "image-reference", [(#"fixedFrame="YES" translates"#, #"fixedFrame="YES" catalog="system" translates"#)])
    #expect(outer.cause.hasPrefix(#"unsupported attribute catalog="system" on <imageView> without an image attribute"#), "\(outer)")
}

@Test func refusesSymbolsOutsideTheVerifiedSet() throws {
    let e = try refusal(of: "image-system-symbol", [(#"image="star.fill" catalog="system" translates"#, #"image="no.such.symbol" catalog="system" translates"#)])
    #expect(e.cause.hasPrefix(#"unsupported: SF Symbol "no.such.symbol""#), "\(e)")
    #expect(e.cause.hasSuffix("(see docs/research/nib-encoding.md#open-questions)"), "\(e)")
}

@Test func missingImagesCompileWithoutWarnings() throws {
    let r = try StoryboardCompiler.compile(url: CorpusCase(name: "image-missing").storyboard,
                                           options: .flagset(named: "universal-16", root: corpusRoot))
    #expect(r.warnings.isEmpty)
}

@Test func verifiedSymbolsAreTheSymbolGridNames() throws {
    let doc = try StoryboardParser.parse(url: CorpusCase(name: "image-symbol-grid").storyboard)
    let names = doc.scenes[0].viewController.view.subviews.compactMap { $0.image?.catalog == "system" ? $0.image?.name : nil }
    #expect(Set(names) == ImageRule.verifiedSymbols)
    #expect(names.count == ImageRule.verifiedSymbols.count)
}

// MARK: R9 (Task 8): label and font inputs without a golden behind them

private let labelAttrs = #" adjustsFontSizeToFit="NO" translatesAutoresizingMaskIntoConstraints="NO""#
private let labelFont = #"<fontDescription key="fontDescription" type="system" pointSize="17"/>"#

@Test func refusesLabelInputsWithoutGoldens() throws {
    let cases: [(String, String, String)] = [
        // attributes and children Xcode writes for features outside the proven set
        (labelAttrs, #" highlighted="YES""# + labelAttrs, #"unsupported attribute highlighted="YES" on <label>"#),
        (labelAttrs, #" adjustsLetterSpacingToFitWidth="YES""# + labelAttrs, #"unsupported attribute adjustsLetterSpacingToFitWidth="YES" on <label>"#),
        (labelAttrs, #" preferredMaxLayoutWidth="42""# + labelAttrs, #"unsupported attribute preferredMaxLayoutWidth="42" on <label>"#),
        (#"<nil key="highlightedColor"/>"#, #"<color key="highlightedColor" systemColor="systemBlueColor"/>"#, #"unsupported color key "highlightedColor" on <label>"#),
        (#"<nil key="highlightedColor"/>"#, #"<nil key="highlightedColor"/><color key="shadowColor" white="0.0" alpha="1" colorSpace="custom" customColorSpace="genericGamma22GrayColorSpace"/>"#,
         #"unsupported color key "shadowColor" on <label>"#),
        (#"<nil key="highlightedColor"/>"#, #"<nil key="highlightedColor"/><color key="tintColor" systemColor="systemBlueColor"/>"#, #"unsupported color key "tintColor" on <label>"#),
        (#"<nil key="highlightedColor"/>"#, "", #"unsupported <label> without <nil key="highlightedColor"/>"#),
        (#"<nil key="textColor"/>"#, #"<nil key="textColor"/><nil key="backgroundColor"/>"#, #"unsupported <nil key="backgroundColor"> on <label>"#),
        (#"<nil key="textColor"/>"#, #"<nil key="textColor"/><color key="textColor" systemColor="labelColor"/>"#,
         #"unsupported <label> with both <nil key="textColor"/> and a text color"#),
        (#"<nil key="textColor"/>"#, #"<color key="textColor" name="NoSuchColor"/>"#,
         #"unsupported named color "NoSuchColor" as textColor without a <namedColor> resource"#),
        (#"<rect key="frame" x="175.5" y="415.5" width="42" height="21"/>"#,
         #"<rect key="frame" x="175.5" y="415.5" width="42" height="21"/><subviews><view contentMode="scaleToFill" id="sub-vw-001"><rect key="frame" x="0.0" y="0.0" width="1" height="1"/></view></subviews>"#,
         "unsupported subview inside a <label>"),
        // attributes Xcode always writes, with other defaults in ibtool when absent
        (#" lineBreakMode="tailTruncation""#, "", "unsupported <label> without lineBreakMode"),
        (#" baselineAdjustment="alignBaselines""#, "", "unsupported <label> without baselineAdjustment"),
        (labelFont, "", "unsupported <label> without <fontDescription>"),
        // values outside the proven sets
        (#"textAlignment="natural""#, #"textAlignment="start""#, #"unsupported textAlignment="start" on <label>"#),
        (#"lineBreakMode="tailTruncation""#, #"lineBreakMode="truncateTail""#, #"unsupported lineBreakMode="truncateTail" on <label>"#),
        (#"baselineAdjustment="alignBaselines""#, #"baselineAdjustment="alignTop""#, #"unsupported baselineAdjustment="alignTop" on <label>"#),
        (#" lineBreakMode="#, #" numberOfLines="-1" lineBreakMode="#, #"unsupported numberOfLines="-1" (supported: whole numbers 0–32767)"#),
        (#" lineBreakMode="#, #" enabled="maybe" lineBreakMode="#, #"unsupported enabled="maybe" (expected YES or NO)"#),
        (labelAttrs, #" horizontalCompressionResistancePriority="0""# + labelAttrs, #"unsupported horizontalCompressionResistancePriority="0" (supported: whole numbers 1–1000)"#),
        (#"text="Label""#, #"text="a&#13;b""#, "unsupported label text with a carriage return"),
        // autoshrink: only the two forms Xcode writes, never with a text style or a minimum above the font size
        (#" adjustsFontSizeToFit="NO""#, #" adjustsFontSizeToFit="YES""#, #"unsupported autoshrink adjustsFontSizeToFit="YES" on <label>"#),
        (#" adjustsFontSizeToFit="NO""#, "", "unsupported autoshrink attributes missing on <label>"),
        (#" adjustsFontSizeToFit="NO""#, #" adjustsFontSizeToFit="NO" minimumScaleFactor="0.5""#,
         #"unsupported autoshrink adjustsFontSizeToFit="NO" minimumScaleFactor="0.5" on <label>"#),
        (#" adjustsFontSizeToFit="NO""#, #" minimumScaleFactor="0.5" minimumFontSize="9""#, #"unsupported autoshrink minimumScaleFactor="0.5" minimumFontSize="9" on <label>"#),
        (#" adjustsFontSizeToFit="NO""#, #" minimumScaleFactor="1""#, #"unsupported minimumScaleFactor="1" (supported: 0 < factor < 1)"#),
        (#" adjustsFontSizeToFit="NO""#, #" minimumScaleFactor="0""#, #"unsupported minimumScaleFactor="0" (supported: 0 < factor < 1)"#),
        (#" adjustsFontSizeToFit="NO""#, #" minimumFontSize="18""#, #"unsupported minimumFontSize="18" (supported: 0 < size ≤ the font size 17.0)"#),
        // dynamic type only with a text style
        (labelAttrs, labelAttrs + #" adjustsFontForContentSizeCategory="YES""#, #"unsupported adjustsFontForContentSizeCategory="YES" without a text style font"#),
        // fonts: only the proven combinations
        (labelFont, #"<fontDescription key="fontDescription" type="boldSystem" weight="heavy" pointSize="17"/>"#, "unsupported attribute weight=\"heavy\" on this <fontDescription>"),
        (labelFont, #"<fontDescription key="fontDescription" type="italicSystem" weight="bold" pointSize="17"/>"#, "unsupported attribute weight=\"bold\" on this <fontDescription>"),
        (labelFont, #"<fontDescription key="fontDescription" style="UICTFontTextStyleBody" pointSize="30"/>"#, "unsupported attribute pointSize=\"30\" on this <fontDescription>"),
        (labelFont, #"<fontDescription key="fontDescription" style="UICTFontTextStyleExtraLargeTitle"/>"#, #"unsupported text style "UICTFontTextStyleExtraLargeTitle""#),
        (labelFont, #"<fontDescription key="fontDescription" type="system" weight="condensed" pointSize="17"/>"#, #"unsupported font weight "condensed""#),
        (labelFont, #"<fontDescription key="fontDescription" type="monospacedDigitSystem" pointSize="17"/>"#, #"unsupported <fontDescription> type="monospacedDigitSystem""#),
        (labelFont, #"<fontDescription key="fontDescription" type="system"/>"#, "unsupported <fontDescription> without pointSize"),
        (labelFont, #"<fontDescription key="fontDescription" type="system" pointSize="0.0"/>"#, #"unsupported font pointSize="0.0""#),
        (labelFont, #"<fontDescription key="fontDescription" type="system" pointSize="17" design="rounded"/>"#, #"unsupported attribute design="rounded" on <fontDescription>"#),
        (labelFont, #"<fontDescription key="fontDescription" name="" family="X" pointSize="17"/>"#, "unsupported custom font with an empty name"),
    ]
    for (from, to, expected) in cases {
        let e = try refusal(of: "label-plain", [(from, to)])
        #expect(e.cause.hasPrefix(expected), "\(e)")
    }
}

/// Open question 3: a font that ships with macOS or the iOS simulator runtime may resolve in ibtool and get its own
/// traits, so it is refused (compared without case, family names too); every other name gets the "not installed" form.
@Test func refusesCustomFontsThatShipWithMacOSOrIOS() throws {
    // PingFang*: CoreText aliases of the dot-named faces in FontServices' PingFangUI.ttc, listed only by
    // CTFontManagerCopyAvailablePostScriptNames(); Rockwell-Regular: activated in the iOS runtime only.
    for name in ["Helvetica-Bold", "helvetica-bold", "AvenirNext-Regular", "Georgia-Bold", "Menlo-Regular", "Avenir Next", ".SFUI-Regular",
                 "PingFangSC-Regular", "PingFangTC-Semibold", "PingFangHK-Light", "Rockwell-Regular", "STHeitiSC-Light"] {
        let e = try refusal(of: "label-plain", [(labelFont, #"<fontDescription key="fontDescription" name="\#(name)" family="X" pointSize="17"/>"#)])
        #expect(e.cause.hasPrefix(#"unsupported: font "\#(name)" ships with macOS or iOS"#), "\(e)")
        #expect(e.cause.hasSuffix("(see docs/research/nib-encoding.md#open-questions)"), "\(e)")
    }
    // ibtool hangs on STXihei (killed after 60 s, twice), so there is no output to verify against.
    for name in ["STXihei", "stxihei"] {
        let e = try refusal(of: "label-plain", [(labelFont, #"<fontDescription key="fontDescription" name="\#(name)" family="X" pointSize="17"/>"#)])
        #expect(e.cause.hasPrefix(#"unsupported: font "\#(name)" cannot be verified (ibtool does not compile it)"#), "\(e)")
        #expect(e.cause.hasSuffix("(see docs/research/nib-encoding.md#open-questions)"), "\(e)")
    }
}

/// The custom-font goldens were compiled with fonts that are installed neither on the Mac that made them nor in the
/// iOS simulator runtime (ibtool's "not installed" form); the refused cases use fonts that ship with both.
@Test func customFontGoldensUseOnlyUnknownFonts() throws {
    var accepted = Set<String>(), refused = Set<String>()
    for c in try allGoldenCases() where c.name.hasPrefix("label-") {
        let doc = try StoryboardParser.parse(url: CorpusCase(name: c.name).storyboard)
        for v in doc.scenes[0].viewController.view.subviews {
            guard let name = v.fontDescription?["name"] else { continue }
            if refusedCases[c.name] == nil { accepted.insert(name) } else { refused.insert(name) }
        }
    }
    #expect(accepted == ["NoSuchFont-Bold", "XlessBrand-Regular", "XlessBrand-BoldItalic", "Xless Brand Display", "xlessbrand-black"])
    #expect(accepted.allSatisfy { !KnownFonts.names.contains($0.lowercased()) })
    #expect(refused == ["Helvetica-Bold", "AvenirNext-Regular"])
    #expect(refused.allSatisfy { KnownFonts.names.contains($0.lowercased()) })
}

@Test func refusesNamedTintColorWithoutResource() throws {
    let e = try refusal(of: "image-tint", [(#"<color key="tintColor" systemColor="systemBlueColor"/>"#, #"<color key="tintColor" name="NoSuchColor"/>"#)])
    #expect(e.cause.hasPrefix(#"unsupported named color "NoSuchColor" as tintColor without a <namedColor> resource (ibtool fails on it)"#), "\(e)")
}

private let centerX = #"<constraint firstItem="aKz-3d-Q8m" firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" id="C03-cn-K03"/>"#
private let ownWidth = #"<constraint firstAttribute="width" constant="100" id="C01-cn-K01"/>"#

/// Constraint inputs outside what the goldens prove (docs/research/nib-encoding.md, section 6 "NSLayoutConstraint").
@Test func refusesConstraintInputsWithoutGoldens() throws {
    func with(_ attrs: String) -> String { #"<constraint firstItem="aKz-3d-Q8m" \#(attrs) id="C03-cn-K03"/>"# }
    let cases: [(String, String, String)] = [
        // attributes, relations and attribute values
        (centerX, with(#"firstAttribute="leadingMargin" secondItem="Ze5-6b-2t3" secondAttribute="leading""#), #"unsupported constraint firstAttribute="leadingMargin""#),
        (centerX, with(#"firstAttribute="top" secondItem="Ze5-6b-2t3" secondAttribute="lastBaseline""#), #"unsupported constraint secondAttribute="lastBaseline""#),
        (centerX, with(#"firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" foo="1""#), #"unsupported attribute foo="1" on <constraint>"#),
        (centerX, with(#"firstAttribute="centerX" relation="equal" secondItem="Ze5-6b-2t3" secondAttribute="centerX""#), #"unsupported constraint relation="equal""#),
        (centerX, with(#"secondItem="Ze5-6b-2t3" secondAttribute="centerX""#), "unsupported <constraint> without firstAttribute"),
        (centerX, with(#"firstAttribute="centerX" secondItem="Ze5-6b-2t3""#), "unsupported constraint with secondItem but no secondAttribute"),
        (centerX, with(#"firstAttribute="centerX" secondAttribute="centerX""#), "unsupported constraint with secondAttribute but no secondItem"),
        (centerX, #"<constraint firstItem="aKz-3d-Q8m" firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX"/>"#, "unsupported <constraint> without an id"),
        (centerX, centerX + #"<constraint firstItem="aKz-3d-Q8m" firstAttribute="centerY" secondItem="Ze5-6b-2t3" secondAttribute="centerY" id="C03-cn-K03"/>"#,
         #"unsupported duplicate constraint id "C03-cn-K03""#),
        // values
        (centerX, with(#"firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" constant="1e3""#), #"unsupported constraint constant="1e3""#),
        (centerX, with(#"firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" constant="+3""#), #"unsupported constraint constant="+3""#),
        (centerX, with(#"firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" multiplier="0""#), #"unsupported constraint multiplier="0" (supported: positive values)"#),
        (centerX, with(#"firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" multiplier="-1:2""#), #"unsupported constraint multiplier="-1:2" (supported: positive ratios)"#),
        (centerX, with(#"firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" multiplier="1.0000001""#), #"unsupported constraint multiplier="1.0000001" (rounds to 1"#),
        (centerX, with(#"firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" multiplier="0.00001""#), #"unsupported constraint multiplier="0.00001" (supported: 0.0001 up to 999999.5)"#),
        (centerX, with(#"firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" multiplier="1234567.8""#), #"unsupported constraint multiplier="1234567.8" (supported: 0.0001 up to 999999.5)"#),
        (centerX, with(#"firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" multiplier="1:3.0000001""#), #"unsupported constraint multiplier="1:3.0000001" (ratio components need at most six significant digits)"#),
        (centerX, with(#"firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" multiplier="16x9""#), #"unsupported constraint multiplier="16x9""#),
        (centerX, with(#"firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" priority="999.5""#), #"unsupported constraint priority="999.5" (supported: whole numbers 1–1000)"#),
        (centerX, with(#"firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" priority="0""#), #"unsupported constraint priority="0""#),
        (centerX, with(#"firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" priority="1001""#), #"unsupported constraint priority="1001""#),
        (centerX, with(#"firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" priority="0750""#), #"unsupported constraint priority="0750""#),
        (centerX, with(#"firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" constant="8" symbolic="NO""#), #"unsupported constraint symbolic="NO""#),
        (centerX, with(#"firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" symbolic="YES""#), "unsupported symbolic constraint without a constant"),
        (centerX, with(#"firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" placeholder="NO""#), #"unsupported constraint placeholder="NO""#),
        (centerX, with(#"firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" identifier="""#), "unsupported constraint with an empty identifier"),
        // shapes without a golden
        (centerX, #"<constraint firstAttribute="top" constant="8" id="C03-cn-K03"/>"#, "unsupported constraint without a second item on top"),
        (centerX, with(#"firstAttribute="width" constant="8""#), "unsupported constraint without a second item on another view"),
        (centerX, #"<constraint firstAttribute="width" constant="393" id="C03-cn-K03"/>"#, "unsupported constraint on the root view's own size"),
        (centerX, #"<constraint firstItem="Ze5-6b-2t3" firstAttribute="width" secondItem="Ze5-6b-2t3" secondAttribute="height" id="C03-cn-K03"/>"#, "unsupported constraint on the root view's own size"),
        (centerX, with(#"firstAttribute="width" secondItem="aKz-3d-Q8m" secondAttribute="height""#), "unsupported constraint between a view and itself outside that view's own constraints"),
        (centerX, #"<constraint firstAttribute="width" secondItem="aKz-3d-Q8m" secondAttribute="height" placeholder="YES" id="C03-cn-K03"/>"#,
         "unsupported placeholder constraint that ibtool drops"),
    ]
    for (from, to, expected) in cases {
        let e = try refusal(of: "real-logo-plus-label", [(from, to)])
        #expect(e.cause.hasPrefix(expected), "\(e)")
    }
    // a constraint in an image view's own list may only refer to that view
    let own = try refusal(of: "real-logo-plus-label", [(ownWidth, #"<constraint firstAttribute="width" secondItem="Ze5-6b-2t3" secondAttribute="width" id="C01-cn-K01"/>"#)])
    #expect(own.cause.hasPrefix(#"unsupported: constraint item "Ze5-6b-2t3" is not the owning view, its safe area or one of its direct subviews"#), "\(own)")
    #expect(own.cause.hasSuffix("(see docs/research/nib-encoding.md#open-questions)"), "\(own)")
    // views sharing an id
    let dup = try refusal(of: "real-logo-plus-label", [(#"id="Lb1-xT-9pQ""#, #"id="aKz-3d-Q8m""#), (#"secondItem="Lb1-xT-9pQ""#, #"secondItem="aKz-3d-Q8m""#),
                                                        (#"firstItem="Lb1-xT-9pQ""#, #"firstItem="aKz-3d-Q8m""#)])
    #expect(dup.cause.hasPrefix(#"unsupported duplicate id "aKz-3d-Q8m""#), "\(dup)")
}

/// Open question 7: an item deeper than the owner's direct subviews; a legacy top/bottom layout guide as an item.
@Test func refusesConstraintItemsOutsideTheOwnersChildren() throws {
    let deep = try refusal(of: "order-objects-list", [(#"<constraint firstItem="Pv1-aa-aaa" firstAttribute="top" secondItem="Lb1-xT-9pQ""#,
                                                       #"<constraint firstItem="Nv1-aa-aaa" firstAttribute="top" secondItem="Lb1-xT-9pQ""#)])
    #expect(deep.cause.hasPrefix(#"unsupported: constraint item "Nv1-aa-aaa" is not the owning view"#), "\(deep)")
    let legacy = try refusal(of: "core-legacy-constraints", [(#"secondItem="Ze5-6b-2t3" secondAttribute="centerY""#, #"secondItem="Llm-lL-Icb" secondAttribute="bottom""#)])
    #expect(legacy.cause.hasPrefix(#"unsupported: constraint item "Llm-lL-Icb" is not the owning view"#), "\(legacy)")
    let unknown = try refusal(of: "real-logo-plus-label", [(centerX, #"<constraint firstItem="aKz-3d-Q8m" firstAttribute="centerX" secondItem="nope" secondAttribute="centerX" id="C03-cn-K03"/>"#)])
    #expect(unknown.cause.hasPrefix(#"unsupported: constraint item "nope""#), "\(unknown)")
}

/// Open question 1 (step 7 of the constraint order): constraints that share the first item, both attributes, the
/// priority and the relation but point at different second items are refused, whatever the second items' kinds.
@Test func refusesConstraintsThatDifferOnlyInTheirSecondItems() throws {
    // two image views, a label and the safe area as second items (the three order-cons-second-item cases are refused
    // as a whole in CorpusGoldenTests)
    let toLabel = #"<constraint firstItem="aKz-3d-Q8m" firstAttribute="centerX" secondItem="Lb1-xT-9pQ" secondAttribute="centerX" id="C08-cn-K08"/>"#
    func toSafeArea(_ extra: String = "") -> String {
        #"<constraint firstItem="aKz-3d-Q8m" firstAttribute="centerX" secondItem="6Tk-OE-BBY" secondAttribute="centerX"\#(extra) id="C09-cn-K09"/>"#
    }
    let tie = try refusal(of: "real-logo-plus-label", [(centerX, centerX + toLabel + toSafeArea())])
    #expect(tie.cause.hasPrefix(#"unsupported: constraints "C08-cn-K08" and "C09-cn-K09" differ only in their second items"#), "\(tie)")
    #expect(tie.cause.hasSuffix("(see docs/research/nib-encoding.md#open-questions)"), "\(tie)")
    // a different priority or relation avoids step 7; the same second item twice is ordered by id
    for extra in [#" priority="750""#, #" relation="greaterThanOrEqual""#] {
        _ = try compileVariant(of: "real-logo-plus-label", [(centerX, centerX + toLabel + toSafeArea(extra))])
    }
    _ = try compileVariant(of: "real-logo-plus-label", [(centerX, centerX + #"<constraint firstItem="aKz-3d-Q8m" firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" constant="8" id="C08-cn-K08"/>"#)])
}

/// Open question 13: two constraints that tie through step 6 but are written in opposite directions (one from the
/// owning view, which step 1 swaps) are not ordered by id in ibtool (`order-cons-mirrored-tie`, 10 of 32 scratch
/// variants), so they are refused, however the owner is written and whatever the attributes: with the same attribute on
/// both sides the root's goldens follow the ids (`order-cons-mirrored-same`), but a subview owner's do not
/// (`order-cons-mirrored-nested`, and 5 cases in a run of the differential check).
@Test func refusesMirroredConstraintTies() throws {
    let img = "aKz-3d-Q8m", root = "Ze5-6b-2t3", safe = "6Tk-OE-BBY"
    func pair(_ a: String, _ b: String) -> String { centerX + a + b }
    let variants: [(String, String)] = [
        (#"<constraint firstItem="\#(root)" firstAttribute="top" secondItem="\#(img)" secondAttribute="bottom" id="C08-cn-K08"/>"#,
         #"<constraint firstItem="\#(img)" firstAttribute="top" secondItem="\#(root)" secondAttribute="bottom" id="C09-cn-K09"/>"#),
        (#"<constraint firstAttribute="leading" secondItem="\#(img)" secondAttribute="trailing" id="C08-cn-K08"/>"#,   // implicit owner
         #"<constraint firstItem="\#(img)" firstAttribute="leading" secondItem="\#(root)" secondAttribute="trailing" id="C09-cn-K09"/>"#),
        (#"<constraint firstItem="\#(root)" firstAttribute="top" secondItem="\#(safe)" secondAttribute="centerY" id="C08-cn-K08"/>"#,
         #"<constraint firstItem="\#(safe)" firstAttribute="top" secondItem="\#(root)" secondAttribute="centerY" id="C09-cn-K09"/>"#),
    ]
    for (a, b) in variants {
        let e = try refusal(of: "real-logo-plus-label", [(centerX, pair(a, b))])
        #expect(e.cause.hasPrefix(#"unsupported: constraints "C08-cn-K08" and "C09-cn-K09" tie but are written in opposite directions"#), "\(e)")
        #expect(e.cause.hasSuffix("(see docs/research/nib-encoding.md#open-questions)"), "\(e)")
    }
    // same attributes, and a subview owner's list
    let same = try refusal(of: "real-logo-plus-label", [(centerX, pair(
        #"<constraint firstItem="\#(root)" firstAttribute="bottom" secondItem="\#(img)" secondAttribute="bottom" id="C08-cn-K08"/>"#,
        #"<constraint firstItem="\#(img)" firstAttribute="bottom" secondItem="\#(root)" secondAttribute="bottom" id="C09-cn-K09"/>"#))])
    #expect(same.cause.hasPrefix(#"unsupported: constraints "C08-cn-K08" and "C09-cn-K09" tie but are written in opposite directions"#), "\(same)")
    let nested = try refusal(of: "order-objects-list", [(#"<constraint firstAttribute="height" constant="100" id="C20-cn-K20"/>"#,
        #"<constraint firstItem="Pv1-aa-aaa" firstAttribute="centerX" secondItem="Nv1-aa-aaa" secondAttribute="centerX" id="C20-cn-K20"/>"#)])
    #expect(nested.cause.hasPrefix(#"unsupported: constraints "C20-cn-K20" and "C21-cn-K21" tie but are written in opposite directions"#), "\(nested)")
    // written in the same direction, a tie is ordered by id (`order-cons-tiebreaks`); a different priority avoids it
    _ = try compileVariant(of: "real-logo-plus-label", [(centerX, pair(
        #"<constraint firstItem="\#(img)" firstAttribute="top" secondItem="\#(root)" secondAttribute="bottom" constant="8" id="C08-cn-K08"/>"#,
        #"<constraint firstItem="\#(img)" firstAttribute="top" secondItem="\#(root)" secondAttribute="bottom" id="C09-cn-K09"/>"#))])
    _ = try compileVariant(of: "real-logo-plus-label", [(centerX, pair(
        #"<constraint firstItem="\#(root)" firstAttribute="top" secondItem="\#(img)" secondAttribute="bottom" priority="750" id="C08-cn-K08"/>"#,
        #"<constraint firstItem="\#(img)" firstAttribute="top" secondItem="\#(root)" secondAttribute="bottom" id="C09-cn-K09"/>"#))])
}

/// leading/trailing paired with left/right in one constraint: ibtool rewrites the attributes (`cons-mixed-horizontal`)
/// and UIKit rejects the pairing at run time. centerX pairs with both families (`order-cons-table-*`).
@Test func refusesMixedHorizontalAttributePairings() throws {
    for (fa, sa) in [("leading", "left"), ("right", "trailing"), ("trailing", "right"), ("left", "leading")] {
        let e = try refusal(of: "real-logo-plus-label", [(centerX,
            #"<constraint firstItem="aKz-3d-Q8m" firstAttribute="\#(fa)" secondItem="Ze5-6b-2t3" secondAttribute="\#(sa)" id="C03-cn-K03"/>"#)])
        #expect(e.cause.hasPrefix(#"unsupported constraint pairing firstAttribute="\#(fa)" with secondAttribute="\#(sa)""#), "\(e)")
    }
    for (fa, sa) in [("centerX", "left"), ("leading", "centerX"), ("left", "right"), ("leading", "trailing")] {
        _ = try compileVariant(of: "real-logo-plus-label", [(centerX,
            #"<constraint firstItem="aKz-3d-Q8m" firstAttribute="\#(fa)" secondItem="Ze5-6b-2t3" secondAttribute="\#(sa)" id="C03-cn-K03"/>"#)])
    }
}

/// Final review I2: numbers only in Xcode's decimal spelling (ibtool reads `0x11` as 0 or 12, not 17). Color
/// components may use the exponent form Xcode writes below 1e-4 (`color-srgb-tiny`, `color-srgb-small-grid`).
@Test func refusesNumberSpellingsXcodeDoesNotWrite() throws {
    let rect = #"<rect key="frame" x="0.0" y="0.0" width="393" height="852"/>"#
    let srgb = #"red="1" green="0.5" blue="0.0" alpha="1""#
    let cases: [(String, String, String)] = [
        ("core-safearea", rect, #"<rect key="frame" x="0x0" y="0.0" width="393" height="852"/>"#),
        ("core-safearea", rect, #"<rect key="frame" x="0.0" y="0.0" width="+393" height="852"/>"#),
        ("core-safearea", rect, #"<rect key="frame" x="0.0" y="0.0" width="3.93e2" height="852"/>"#),
        ("core-safearea", rect, #"<rect key="frame" x="0.0" y="0.0" width="0393" height="852"/>"#),
        ("core-safearea", rect, #"<rect key="frame" x=".5" y="0.0" width="393" height="852"/>"#),
        ("core-safearea", rect, #"<rect key="frame" x="-0.0" y="0.0" width="393" height="852"/>"#),
        ("color-srgb-opaque", srgb, #"red="0x1" green="0.5" blue="0.0" alpha="1""#),
        ("color-srgb-opaque", srgb, #"red="+1" green="0.5" blue="0.0" alpha="1""#),
        ("color-srgb-opaque", srgb, #"red="1." green="0.5" blue="0.0" alpha="1""#),
        ("color-srgb-opaque", srgb, #"red="1" green="5e-1" blue="0.0" alpha="1""#),
        ("color-srgb-opaque", srgb, #"red="1" green="0.5" blue="1E-05" alpha="1""#),
        ("color-srgb-opaque", srgb, #"red="1" green="0.5" blue="1e+00" alpha="1""#),
        ("color-srgb-opaque", srgb, #"red="1" green="0.5" blue="0.0" alpha=" 1""#),
        ("color-system-systemBlueColor", #"systemColor="systemBlueColor""#, #"systemColor="systemBlueColor" red="0x1""#),
        ("label-plain", #"pointSize="17""#, #"pointSize="0x11""#),
        ("label-plain", #"pointSize="17""#, #"pointSize="1.7e1""#),
        ("label-plain", #"pointSize="17""#, #"pointSize="+17""#),
        ("label-plain", #"pointSize="17""#, #"pointSize="17.""#),
        ("label-keys-combined", #"minimumScaleFactor="0.5""#, #"minimumScaleFactor="5e-1""#),
        ("label-keys-combined", #"minimumScaleFactor="0.5""#, #"minimumScaleFactor="0x0.8p0""#),
        ("label-autoshrink-grid", #"minimumFontSize="10""#, #"minimumFontSize="0xA""#),
        ("cons-constant-negative", #"constant="-40""#, #"constant="-040""#),
        ("cons-constant-negative", #"constant="-40""#, #"constant="-4e1""#),
    ]
    for (name, anchor, replacement) in cases {
        let e = try refusal(of: name, [(anchor, replacement)])
        #expect(e.stage == .ib)
        #expect(["unsupported number", "unsupported constraint", "unsupported color with both"].contains { e.cause.hasPrefix($0) },
                "\(replacement): \(e.cause)")
    }
    // A constraint constant of -0.0 is proven (`cons-values-grid`); a frame's is not.
    _ = try compileVariant(of: "cons-constant-negative", [(#"constant="-40""#, #"constant="-0.0""#)])
    // The exponent form Xcode writes for tiny color components compiles.
    _ = try compileVariant(of: "color-srgb-opaque", [(srgb, #"red="1" green="0.5" blue="1.0000000000000001e-05" alpha="1""#)])
}

/// Final review M3: a second `<view>` under the view controller (another key, e.g. an input accessory view) is not
/// part of any golden; it is refused instead of silently dropped.
@Test func refusesASecondViewUnderTheViewController() throws {
    let anchor = "                    </view>\n                </viewController>"
    let second = #"<view key="inputAccessoryView" contentMode="scaleToFill" id="Acc-aa-aaa"><rect key="frame" x="0.0" y="0.0" width="393" height="44"/></view>"#
    for (extra, line) in [(second, 20), (second.replacingOccurrences(of: "inputAccessoryView", with: "view"), 20)] {
        let e = try refusal([(anchor, "                    </view>\n" + extra + "\n                </viewController>")])
        #expect(e.stage == .ib)
        #expect(e.cause.hasPrefix("unsupported element <view> at line \(line)"), "\(e.cause)")
    }
}
