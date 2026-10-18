import Foundation
import Testing
@testable import XlessIB

/// Value tag 5 is YES and tag 4 is NO (docs/research/nib-encoding.md, "Booleans").
private func goldenValue(_ caseName: String, className: String, key: String) throws -> NIBValueData? {
    let dir = corpusRoot.appendingPathComponent("golden/27A266a/\(caseName)/universal-16.storyboardc")
    let nib = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .first { $0.lastPathComponent.contains("-view-") })
    let a = try NIBArchiveReader.read(Data(contentsOf: nib))
    for o in a.objects where a.classNames[o.classNameIndex].string == className {
        for v in a.values[o.valuesStart..<(o.valuesStart + o.valueCount)] where String(decoding: a.keys[v.keyIndex], as: UTF8.self) == key {
            return v.data
        }
    }
    return nil
}

@Test func goldenYesDecodesAsTrue() throws {
    // image-catalog-scaleAspectFit: the image view has clipsSubviews="YES"; image-no-clips has no UIClipsToBounds at all.
    #expect(try goldenValue("image-catalog-scaleAspectFit", className: "UIImageView", key: "UIClipsToBounds") == .bool(true))
    #expect(try goldenValue("image-no-clips", className: "UIImageView", key: "UIClipsToBounds") == nil)
    // label-system-17-regular: a system font, so UISystemFont is YES; label-custom-font (Helvetica-Bold) is NO.
    #expect(try goldenValue("label-system-17-regular", className: "UIFont", key: "UISystemFont") == .bool(true))
    #expect(try goldenValue("label-custom-font", className: "UIFont", key: "UISystemFont") == .bool(false))
}

@Test func writerEmitsTag5ForTrueAnd4ForFalse() {
    var a = NIBArchive()
    a.classNames = [NIBClassName(name: Data("NSObject".utf8), extras: [])]
    a.keys = [Data("k".utf8)]
    a.values = [NIBValue(keyIndex: 0, data: .bool(true)), NIBValue(keyIndex: 0, data: .bool(false))]
    a.objects = [NIBObject(classNameIndex: 0, valuesStart: 0, valueCount: 2)]
    let d = NIBArchiveWriter.write(a)
    let valuesOffset = Int(d[38]) | Int(d[39]) << 8 | Int(d[40]) << 16 | Int(d[41]) << 24  // header: values (count, offset) at 34, 38
    // Each value: key varint (0x80 = key 0, last byte), then the type tag.
    #expect(Array(d[valuesOffset..<(valuesOffset + 4)]) == [0x80, 5, 0x80, 4])
}

@Test func dumpPrintsYesAsTrue() throws {
    let dir = corpusRoot.appendingPathComponent("golden/27A266a/image-catalog-scaleAspectFit/universal-16.storyboardc")
    let nib = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .first { $0.lastPathComponent.contains("-view-") })
    let dump = NIBDump.render(try NIBArchiveReader.read(Data(contentsOf: nib)))
    #expect(dump.contains("  UIClipsToBounds = true\n"))
}
