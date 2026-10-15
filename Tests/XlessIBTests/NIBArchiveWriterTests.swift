import Testing
import Foundation
import XlessCore
@testable import XlessIB

@Test func writerReproducesEveryGoldenNibByteForByte() throws {
    for url in try goldenNibs() {
        let bytes = try Data(contentsOf: url)
        let rewritten = NIBArchiveWriter.write(try NIBArchiveReader.read(bytes))
        #expect(rewritten == bytes, "round-trip differs for \(url.lastPathComponent)")
    }
}

@Test func goldenNibsCarryConstantLNETrailer() throws {
    for url in try goldenNibs() {
        let a = try NIBArchiveReader.read(Data(contentsOf: url))
        #expect(a.trailer == Data([0x4C, 0x4E, 0x45, 0x00]), "trailer differs for \(url.lastPathComponent)")
    }
}

@Test func writerRoundTripsSyntheticArchive() throws {
    var a = NIBArchive()
    a.classNames = [NIBClassName(name: Data("NSObject".utf8), extras: [])]
    a.keys = [Data("k".utf8)]
    a.values = [NIBValue(keyIndex: 0, data: .double(1.5)), NIBValue(keyIndex: 0, data: .data(Data([1, 2, 3])))]
    a.objects = [NIBObject(classNameIndex: 0, valuesStart: 0, valueCount: 2)]
    #expect(try NIBArchiveReader.read(NIBArchiveWriter.write(a)) == a)
    a.trailer = Data([1, 2])
    #expect(try NIBArchiveReader.read(NIBArchiveWriter.write(a)) == a)
}

@Test func freshArchiveEndsWithIbtoolTrailer() {
    var a = NIBArchive()
    a.classNames = [NIBClassName(name: Data("NSObject".utf8), extras: [])]
    a.objects = [NIBObject(classNameIndex: 0, valuesStart: 0, valueCount: 0)]
    #expect(NIBArchiveWriter.write(a).suffix(4) == Data([0x4C, 0x4E, 0x45, 0x00]))
}

@Test func writerRoundTripsWideSyntheticArchive() throws {
    var a = NIBArchive()
    a.sectionOrder = [.classNames, .values, .keys, .objects]
    a.classNames = [NIBClassName(name: Data("NSObject".utf8), extras: []),
                    NIBClassName(name: Data("UIColor".utf8), extras: [8, -3, Int32.max])]
    a.keys = (0..<300).map { Data("key\($0)".utf8) }
    let cases: [NIBValueData] = [.int8(-5), .int16(-300), .int32(-70000), .int64(-5_000_000_000), .bool(true), .bool(false),
                                 .float(2.5), .double(-1.25), .data(Data(repeating: 7, count: 200)), .data(Data()), .null, .object(4_000_000_000)]
    a.values = (0..<300).map { NIBValue(keyIndex: $0, data: cases[$0 % cases.count]) }
    a.objects = [NIBObject(classNameIndex: 0, valuesStart: 0, valueCount: 300), NIBObject(classNameIndex: 1, valuesStart: 150, valueCount: 150)]
    #expect(try NIBArchiveReader.read(NIBArchiveWriter.write(a)) == a)
}

private func archiveWithOffsets(_ mutate: (inout Data) -> Void) throws -> Data {
    var a = NIBArchive()
    a.classNames = [NIBClassName(name: Data("NSObject".utf8), extras: [])]
    a.keys = [Data("k".utf8)]
    a.values = [NIBValue(keyIndex: 0, data: .null)]
    a.objects = [NIBObject(classNameIndex: 0, valuesStart: 0, valueCount: 1)]
    var d = NIBArchiveWriter.write(a)
    mutate(&d)
    return d
}

private func addToOffset(_ d: inout Data, field: Int, _ delta: Int) {
    let at = 18 + field * 8 + 4
    var v = UInt32(d[at]) | UInt32(d[at + 1]) << 8 | UInt32(d[at + 2]) << 16 | UInt32(d[at + 3]) << 24
    v = UInt32(Int(v) + delta)
    for k in 0..<4 { d[at + k] = UInt8((v >> (8 * UInt32(k))) & 0xFF) }
}

@Test func readerRejectsGapBetweenSections() throws {
    // shift keys (and following sections' reads) one byte later, leaving a gap after objects
    let d = try archiveWithOffsets { d in d.insert(0, at: 50 + 3); for f in [1, 2, 3] { addToOffset(&d, field: f, 1) } }
    #expect(throws: XlessError.self) { try NIBArchiveReader.read(d) }
}

@Test func readerRejectsOverlappingSections() throws {
    let d = try archiveWithOffsets { d in addToOffset(&d, field: 1, -1); addToOffset(&d, field: 2, -1); addToOffset(&d, field: 3, -1) }
    #expect(throws: XlessError.self) { try NIBArchiveReader.read(d) }
}

@Test func readerPreservesArbitraryTrailerVerbatim() throws {
    var a = NIBArchive()
    a.classNames = [NIBClassName(name: Data("NSObject".utf8), extras: [])]
    a.trailer = Data([9, 8, 7, 6, 5])
    let bytes = NIBArchiveWriter.write(a)
    #expect(NIBArchiveWriter.write(try NIBArchiveReader.read(bytes)) == bytes)
}

@Test func roundTripsWithEmptySectionSharingOffsetWithNonEmpty() throws {
    var a = NIBArchive()
    a.sectionOrder = [.keys, .objects, .values, .classNames]   // keys empty, shares offset 50 with objects
    a.classNames = [NIBClassName(name: Data("NSObject".utf8), extras: [])]
    a.objects = [NIBObject(classNameIndex: 0, valuesStart: 0, valueCount: 0)]
    #expect(try NIBArchiveReader.read(NIBArchiveWriter.write(a)) == a)
}

@Test func roundTripsWithTwoEmptySections() throws {
    var a = NIBArchive()
    a.sectionOrder = [.objects, .keys, .values, .classNames]   // keys and values empty, same offset
    a.classNames = [NIBClassName(name: Data("NSObject".utf8), extras: [])]
    a.objects = [NIBObject(classNameIndex: 0, valuesStart: 0, valueCount: 0)]
    #expect(try NIBArchiveReader.read(NIBArchiveWriter.write(a)) == a)
    a.sectionOrder = [.keys, .values, .objects, .classNames]   // two leading empties
    #expect(try NIBArchiveReader.read(NIBArchiveWriter.write(a)) == a)
}
