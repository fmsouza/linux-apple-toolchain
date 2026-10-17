import Testing
import Foundation
@testable import XlessTauri

/// The shape `xcrun assetutil --info` prints: the car's header first, then one object per rendition.
private let assetutilJSON = """
[
  { "AssetStorageVersion": "IBCocoaTouchImageCatalogTool-25098", "Platform": "ios", "StorageVersion": 17 },
  { "AssetType": "Image", "BitsPerComponent": 8, "ColorModel": "RGB", "Colorspace": "srgb", "Compression": "deepmap2",
    "Encoding": "ARGB", "Idiom": "universal", "Name": "Badge", "NameIdentifier": 1234, "Opaque": false,
    "PixelHeight": 40, "PixelWidth": 40, "RenditionName": "Badge@2x.png", "Scale": 2, "SHA1Digest": "AB",
    "SizeOnDisk": 900, "Template Mode": "automatic" },
  { "AssetType": "Color", "Color components": [1, 0.5, 0.25, 1], "Colorspace": "srgb", "Idiom": "universal",
    "Name": "Tint", "NameIdentifier": 99, "Scale": 1 },
  { "AssetType": "PackedImage", "Encoding": "ARGB", "Idiom": "universal", "Name": "ZZZZPackedAsset-1.0.0-gamut0",
    "Opaque": false, "PixelHeight": 52, "PixelWidth": 102, "Scale": 1 }
]
"""

@Test func assetCatalogLinesKeepRenderingFieldsOnly() throws {
    let lines = try AssetCatalogReport.renditions(assetutilJSON: Data(assetutilJSON.utf8), car: "Assets.car")
    #expect(lines == [
        "AssetType=Color|Name=Tint|Idiom=universal|Scale=1|Colorspace=srgb|Color components=[1,0.5,0.25,1]",
        "AssetType=Image|Name=Badge|Idiom=universal|Scale=2|Opaque=false|Encoding=ARGB|ColorModel=RGB|Colorspace=srgb|"
            + "BitsPerComponent=8|PixelWidth=40|PixelHeight=40|Template Mode=automatic",
    ])
    #expect(AssetCatalogReport.identity(lines[1]) == "Badge/universal/2/-/Image")
}

@Test func assetCatalogDiffSeesOpacityAndAllowsKnownGaps() throws {
    let reference = try AssetCatalogReport.renditions(assetutilJSON: Data(assetutilJSON.utf8), car: "Assets.car")
    let opaque = reference.map { $0.replacingOccurrences(of: "Opaque=false", with: "Opaque=true") }
    #expect(AssetCatalogReport.diff(reference: ["Assets.car": reference], actual: ["Assets.car": reference], allowed: []).isEmpty)

    let d = AssetCatalogReport.diff(reference: ["Assets.car": reference], actual: ["Assets.car": opaque], allowed: [])
    #expect(d.count == 1)
    #expect(d[0].hasPrefix("car:Assets.car:Badge/universal/2/-/Image reference=") && d[0].contains("actual=AssetType=Image|Name=Badge|Idiom=universal|Scale=2|Opaque=true"))

    let missing = AssetCatalogReport.diff(reference: ["Assets.car": reference], actual: ["Assets.car": [reference[1]]], allowed: [])
    #expect(missing == ["car:Assets.car:Tint/universal/1/-/Color missing from actual: \(reference[0])"])
    #expect(AssetCatalogReport.diff(reference: ["Assets.car": reference], actual: ["Assets.car": [reference[1]]],
                                    allowed: ["car:Assets.car:Tint/universal/1/-/Color"]).isEmpty)
    #expect(AssetCatalogReport.diff(reference: ["Assets.car": reference], actual: [:], allowed: []) == ["car:Assets.car missing from actual"])
}

@Test func bundleReportComparesCatalogsOnlyWhenBothSidesHaveThem() throws {
    let app = try makeApp(); defer { try? FileManager.default.removeItem(at: app) }
    var reference = try BundleReport.make(app: app)
    reference.assetCatalogs = ["Assets.car": ["AssetType=Image|Name=Badge|Opaque=false"]]
    var actual = reference
    actual.assetCatalogs = nil
    #expect(BundleReport.diff(reference: reference, actual: actual, allowed: []).isEmpty)
    actual.assetCatalogs = ["Assets.car": ["AssetType=Image|Name=Badge|Opaque=true"]]
    #expect(BundleReport.diff(reference: reference, actual: actual, allowed: []).map { $0.prefix(while: { $0 != " " }) }
            == ["car:Assets.car:Badge/-/-/-/Image"])

    // References recorded before asset catalogs were reported decode without them, and encode without the key.
    var old = reference
    old.assetCatalogs = nil
    let json = try old.json()
    #expect(!String(decoding: json, as: UTF8.self).contains("assetCatalogs"))
    #expect(try JSONDecoder().decode(BundleReport.self, from: json).assetCatalogs == nil)
}
