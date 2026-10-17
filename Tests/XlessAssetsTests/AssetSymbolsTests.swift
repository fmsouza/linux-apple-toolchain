import Testing
import Foundation
@testable import XlessAssets
@testable import XlessCore

// Symbol names actool 27.0 generated for these asset names (color and image sets alike).
@Test(arguments: [
    ("SplashScreenBackground", "splashScreenBackground", "SplashScreenBackground"),
    ("SplashScreenLogo", "splashScreenLogo", "SplashScreenLogo"),
    ("AccentColor", "accent", "AccentColor"),
    ("accentColor", "accent", "AccentColor"),
    ("Brand Color", "brand", "BrandColor"),
    ("hero-image", "hero", "HeroImage"),
    ("BackgroundImage", "background", "BackgroundImage"),
    ("redColor", "red", "RedColor"),
    ("inner_icon", "innerIcon", "InnerIcon"),
    ("snake_case_Name", "snakeCaseName", "SnakeCaseName"),
    ("logo dark", "logoDark", "LogoDark"),
    ("Logo__x", "logoX", "LogoX"),
    ("My Logo 2", "myLogo2", "MyLogo2"),
    ("icon2x", "icon2X", "Icon2X"),
    ("2fa", "_2Fa", "2Fa"),
    ("URLIcon", "urlIcon", "URLIcon"),
    ("iconURL", "iconURL", "IconURL"),
    ("ABC", "ABC", "ABC"),
    ("a", "a", "A"),
    ("Color", "color", "Color"),
    ("Image", "image", "Image"),
    ("Images", "images", "Images"),
    ("ColorColor", "color", "ColorColor"),
    ("default", "`default`", "Default"),
    ("Self", "`self`", "Self"),
])
func symbolNamesFollowActool(name: String, swift: String, objcSuffix: String) {
    #expect(AssetSymbols.swiftSymbol(name) == swift)
    #expect(AssetSymbols.objcSymbol(name, kind: .color) == "ACColorName" + objcSuffix)
    #expect(AssetSymbols.objcSymbol(name, kind: .image) == "ACImageName" + objcSuffix)
}

@Test func namesOutsideTheVerifiedSubsetGetNoSymbolAndAWarning() throws {
    #expect(AssetSymbols.swiftSymbol("über") == nil)
    #expect(AssetSymbols.swiftSymbol("a.b") == nil)
    let cat = URL(fileURLWithPath: "/c.xcassets")
    let out = try AssetSymbols.generate([.init(name: "über", kind: .image, catalog: cat, relativePath: "über.imageset")],
                                        bundleIdentifier: "a.b", backDeploy: true)
    #expect(out.warnings == ["/c.xcassets/über.imageset: warning: xless generates no asset symbol for the name \"über\" (supported: ASCII letters, digits, space, - and _)"])
    #expect(!out.swift.contains("über"))
    #expect(!out.objc.contains("über"))
}

@Test func collidingSwiftSymbolsBecomeAWarningAsActoolWritesIt() throws {
    let cat = URL(fileURLWithPath: "/c.xcassets")
    let out = try AssetSymbols.generate([.init(name: "Color", kind: .color, catalog: cat, relativePath: "Color.colorset"),
                                         .init(name: "ColorColor", kind: .color, catalog: cat, relativePath: "ColorColor.colorset")],
                                        bundleIdentifier: "a.b", backDeploy: true)
    #expect(out.swift.contains("""
        extension ColorResource {

            /// The "Color" asset catalog color resource.
            static let color = ColorResource(name: "Color", bundle: resourceBundle)

            #warning("The \\"ColorColor\\" color asset name resolves to the symbol \\"color\\" which already exists. Try renaming the asset.")

        }
        """))
    // Both keep their Objective-C constant and their index entry.
    #expect(out.objc.contains("ACColorNameColorColor"))
}

@Test func assetsAreSortedByNameAcrossGroupsAndNamespacesAreRefused() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sym-\(UUID()).xcassets")
    let fm = FileManager.default
    for dir in ["b.imageset", "Folder/A.imageset", "C.colorset", "AppIcon.appiconset"] {
        try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8).write(to: root.appendingPathComponent("Folder/Contents.json"))
    let assets = try AssetSymbols.assets(in: [root])
    #expect(assets.map(\.name) == ["A", "C", "b"])
    #expect(assets.map(\.relativePath) == ["Folder/A.imageset", "C.colorset", "b.imageset"])

    try Data(#"{"info":{"author":"xcode","version":1},"properties":{"provides-namespace":true}}"#.utf8)
        .write(to: root.appendingPathComponent("Folder/Contents.json"))
    #expect(throws: XlessError.self) { try AssetSymbols.assets(in: [root]) }
}
