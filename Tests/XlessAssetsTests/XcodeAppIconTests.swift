import Testing
import Foundation
import PNG
@testable import XlessAssets
@testable import XlessCore

/// A real (decodable) opaque RGB PNG filled with one colour.
func solidPNG(_ size: Int, r: UInt8, g: UInt8, b: UInt8) throws -> Data {
    let px = [PNG.RGBA<UInt8>](repeating: .init(r, g, b, 255), count: size * size)
    let img = PNG.Image(packing: px, size: (size, size), layout: .init(format: .rgb8(palette: [], fill: nil, key: nil)))
    var out = PNGBytes()
    try img.compress(stream: &out, level: 1)
    return Data(out.bytes)
}

func decodePNG(_ d: Data) throws -> PNG.Image {
    var src = PNGBytes(bytes: [UInt8](d))
    return try PNG.Image.decompress(stream: &src)
}

func singleSizeCatalog(icon: Data) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cat-\(UUID()).xcassets")
    let set = root.appendingPathComponent("AppIcon.appiconset")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8).write(to: root.appendingPathComponent("Contents.json"))
    try Data(#"{"images":[{"filename":"i.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}"#.utf8)
        .write(to: set.appendingPathComponent("Contents.json"))
    try icon.write(to: set.appendingPathComponent("i.png"))
    return root
}

@Test func normalizeSplitsSingleSizeIconIntoPhoneAndPad() throws {
    // actool files the single-size icon under the phone and pad idioms; AssetKit keeps whatever idiom it is given.
    let src = Data(#"{"images":[{"filename":"a.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"version":1}}"#.utf8)
    let images = try #require((JSONSerialization.jsonObject(with: AssetsStage.normalizedAppIconContents(src)) as? [String: Any])?["images"] as? [[String: Any]])
    #expect(images.map { $0["idiom"] as? String } == ["iphone", "ipad"])
    #expect(images.allSatisfy { $0["filename"] as? String == "a.png" && $0["size"] as? String == "1024x1024" && $0["scale"] as? String == "1x" })
}

@Test func singleSizeDetection() throws {
    #expect(XcodeAppIcon.isSingleSize(Data(#"{"images":[{"filename":"a.png","idiom":"universal","platform":"ios","size":"1024x1024"}]}"#.utf8)))
    #expect(!XcodeAppIcon.isSingleSize(Data(#"{"images":[{"filename":"a.png","idiom":"iphone","scale":"2x","size":"60x60"}]}"#.utf8)))
}

@Test func iconPlistMatchesXcodeForUniversalApp() {
    let p = XcodeAppIcon.plistAdditions(name: "AppIcon", deviceFamily: [1, 2])
    let phone = (p["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
    let pad = (p["CFBundleIcons~ipad"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
    #expect(phone?["CFBundleIconFiles"] as? [String] == ["AppIcon60x60"])
    #expect(phone?["CFBundleIconName"] as? String == "AppIcon")
    #expect(pad?["CFBundleIconFiles"] as? [String] == ["AppIcon60x60", "AppIcon76x76"])
    #expect(pad?["CFBundleIconName"] as? String == "AppIcon")
    #expect(p["CFBundleIconName"] == nil)
    #expect(p["CFBundleIconFiles"] == nil)
    #expect(Set(p.keys) == ["CFBundleIcons", "CFBundleIcons~ipad"])
}

@Test func iconPlistNamesIconOnlyForTargetedFamilies() {
    // Observed with Xcode 27.0, TARGETED_DEVICE_FAMILY=1 / =2: both dictionaries and both files are always
    // emitted; CFBundleIconName appears only in the targeted family's dictionary.
    let phoneOnly = XcodeAppIcon.plistAdditions(name: "AppIcon", deviceFamily: [1])
    #expect(((phoneOnly["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any])?["CFBundleIconName"] as? String == "AppIcon")
    #expect(((phoneOnly["CFBundleIcons~ipad"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any])?["CFBundleIconName"] == nil)
    let padOnly = XcodeAppIcon.plistAdditions(name: "AppIcon", deviceFamily: [2])
    #expect(((padOnly["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any])?["CFBundleIconName"] == nil)
    #expect(((padOnly["CFBundleIcons~ipad"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any])?["CFBundleIconFiles"] as? [String]
        == ["AppIcon60x60", "AppIcon76x76"])
}

@Test func looseIconFilesAreDownscaledOpaquePNGs() throws {
    let files = try XcodeAppIcon.looseFiles(name: "AppIcon", icon1024: solidPNG(256, r: 10, g: 200, b: 30))
    #expect(files.map(\.name) == ["AppIcon60x60@2x.png", "AppIcon76x76@2x~ipad.png"])
    for (f, px) in zip(files, [120, 152]) {
        let img = try decodePNG(f.data)
        #expect(img.size.x == px && img.size.y == px)
        guard case .rgb8 = img.layout.format else { Issue.record("expected opaque RGB, got \(img.layout.format)"); continue }
        let c = img.unpack(as: PNG.RGBA<UInt8>.self)[px * px / 2]
        #expect((c.r, c.g, c.b, c.a) == (10, 200, 30, 255))
    }
}

@Test func downscaleAveragesSourcePixels() throws {
    // 2x2 -> 1x1: left column black, right column white -> mid grey.
    let px: [PNG.RGBA<UInt8>] = [.init(0, 0, 0, 255), .init(255, 255, 255, 255), .init(0, 0, 0, 255), .init(255, 255, 255, 255)]
    let img = PNG.Image(packing: px, size: (2, 2), layout: .init(format: .rgb8(palette: [], fill: nil, key: nil)))
    var out = PNGBytes(); try img.compress(stream: &out)
    let c = try decodePNG(XcodeAppIcon.downscale(png: Data(out.bytes), to: 1)).unpack(as: PNG.RGBA<UInt8>.self)[0]
    #expect((c.r, c.g, c.b) == (128, 128, 128))
}

@Test func iosSingleSizeIconMatchesXcodeBundleLayout() async throws {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("in-\(UUID())/X.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try Plist.write(["CFBundleExecutable": "X", "UIDeviceFamily": [1, 2], "CFBundleIconFile": "old"],
                    to: app.appendingPathComponent("Info.plist"), stage: .assets)
    let cat = try singleSizeCatalog(icon: solidPNG(256, r: 1, g: 2, b: 3))  // small source keeps debug-build PNG coding fast
    let yaml = """
    bundleID: a.b
    teamID: ABCDE12345
    version: "1"
    build: 1
    platforms:
      ios: { minimumOS: "17.0", product: X }
    assets: \(cat.path)
    """
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID())")
    let r = try await AssetsStage.run(input: app, outputDir: out, platform: .ios,
                                      config: ProjectConfig.parse(yaml: yaml), project: URL(fileURLWithPath: "/"))
    let files = try FileManager.default.contentsOfDirectory(atPath: r.path).sorted()
    #expect(files == ["AppIcon60x60@2x.png", "AppIcon76x76@2x~ipad.png", "Assets.car", "Info.plist"])
    let info = try Plist.read(r.appendingPathComponent("Info.plist"), stage: .assets)
    #expect(info["CFBundleIconName"] == nil)
    #expect(info["CFBundleIconFile"] == nil)
    #expect(info["CFBundleIconFiles"] == nil)
    #expect(((info["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any])?["CFBundleIconFiles"] as? [String] == ["AppIcon60x60"])
    #expect(((info["CFBundleIcons~ipad"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any])?["CFBundleIconName"] as? String == "AppIcon")
}
