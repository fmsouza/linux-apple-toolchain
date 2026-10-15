import Testing
import Foundation
import XlessCore
@testable import XlessIB

let corpusRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("IBCorpus")

func goldenNibs() throws -> [URL] {
    let golden = corpusRoot.appendingPathComponent("golden")
    let e = FileManager.default.enumerator(at: golden, includingPropertiesForKeys: nil)!
    return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "nib" }.sorted { $0.path < $1.path }
}

@Test func readsEveryGoldenNib() throws {
    let nibs = try goldenNibs()
    #expect(!nibs.isEmpty)
    for url in nibs {
        let a = try NIBArchiveReader.read(Data(contentsOf: url))
        #expect(a.formatVersion == 1)
        #expect(a.coderVersion == 10)
        #expect(!a.objects.isEmpty)
        for o in a.objects {
            #expect(o.classNameIndex < a.classNames.count)
            #expect(o.valuesStart + o.valueCount <= a.values.count)
        }
        for v in a.values { #expect(v.keyIndex < a.keys.count) }
    }
}

@Test func dumpIsStableAndNamesClasses() throws {
    let url = try #require(goldenNibs().first { $0.lastPathComponent.hasPrefix("UIViewController-") })
    let a = try NIBArchiveReader.read(Data(contentsOf: url))
    let d1 = NIBDump.render(a), d2 = NIBDump.render(a)
    #expect(d1 == d2)
    #expect(d1.contains("UIViewController"))
}

@Test func rejectsBadMagic() {
    #expect(throws: XlessError.self) { try NIBArchiveReader.read(Data("NOTANIB...".utf8)) }
}

// MARK: - Hostile input

private func goldenData() throws -> Data {
    try Data(contentsOf: #require(goldenNibs().first { $0.lastPathComponent.hasPrefix("UIViewController-") }))
}

/// Header: magic, version 1, coder 10, then (count, offset) pairs for objects, keys, values, classes.
private func archive(_ pairs: [UInt32], body: [UInt8] = []) -> Data {
    var d = Data("NIBArchive".utf8)
    for v in [1, 10] + pairs { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: body)
    return d
}

private func setU32(_ d: inout Data, at off: Int, _ v: UInt32) {
    for k in 0..<4 { d[off + k] = UInt8((v >> (8 * UInt32(k))) & 0xFF) }
}

private func expectIBError(_ d: Data, _ sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(throws: XlessError.self, sourceLocation: sourceLocation) { try NIBArchiveReader.read(d) }
}

// header field offsets: objects count 18, offset 22; keys 26/30; values 34/38; classes 42/46
@Test func truncatedSectionsThrow() throws {
    let g = try goldenData()
    for cut in [60, 107 + 5, 476 + 10, 812 + 3, g.count - 8] {
        expectIBError(g.prefix(cut))
    }
}

@Test func sectionOffsetPastEOFThrows() throws {
    for field in [22, 30, 38, 46] {
        var g = try goldenData()
        setU32(&g, at: field, UInt32(g.count + 100))
        expectIBError(g)
    }
}

@Test func sectionOffsetInsideHeaderThrows() throws {
    var g = try goldenData()
    setU32(&g, at: 22, 10)
    expectIBError(g)
}

@Test func overlongVarintThrows() {
    expectIBError(archive([1, 50, 0, 60, 0, 60, 0, 60], body: Array(repeating: 0x01, count: 10) + [0x81]))
}

@Test func hugeKeyLengthThrows() {
    // one key whose length varint is 0x7F...FF (9 bytes)
    let huge: [UInt8] = Array(repeating: 0x7F, count: 8) + [0xFF]
    expectIBError(archive([0, 50, 1, 50, 0, 60, 0, 60], body: huge + [0x41]))
}

@Test func hugeDataLengthThrows() {
    let huge: [UInt8] = Array(repeating: 0x7F, count: 8) + [0xFF]
    // one value: key 0, type 8 (data), huge length
    expectIBError(archive([0, 50, 0, 50, 1, 50, 0, 60], body: [0x80, 8] + huge))
}

@Test func unknownValueTypeThrows() {
    expectIBError(archive([0, 50, 0, 50, 1, 50, 0, 60], body: [0x80, 0x63]))
}

@Test func outOfRangeIndicesThrow() throws {
    // object 0 is the first object record at offset 50: classIdx, valuesStart, valueCount (single-byte varints)
    var g = try goldenData()
    g[50] = 0xFF                        // classNameIndex 127
    expectIBError(g)

    g = try goldenData()
    g[51] = 0xFF                        // valuesStart 127 > 43 values
    expectIBError(g)

    g = try goldenData()
    g[52] = 0xFF                        // valueCount 127
    expectIBError(g)

    // value 0 starts at 476 with its key index varint
    g = try goldenData()
    g[476] = 0xFF                       // keyIndex 127 > 19 keys
    expectIBError(g)
}

@Test func varintOverflowIsDistinctFromTruncated() {
    var i = 0
    let huge = Data(Array(repeating: 0x7F, count: 8) + [0xFF])
    do { _ = try Varint.decode(huge, at: &i); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.cause.contains("overflow")) }
    catch { Issue.record("wrong error \(error)") }
}

@Test func dumpEscapesControlCharacters() {
    let s = NIBDump.describe(.data(Data("a\nb\u{1}\"c".utf8)))
    #expect(!s.contains("\n"))
    #expect(s.contains("\\n"))
}

/// Final review M1: `xless nib dump` of a missing or unreadable file is an `[ib]` error.
@Test func readingAMissingFileIsAnIBError() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID()).nib")
    let e = try #require(throws: XlessError.self) { try NIBArchiveReader.read(url: url) }
    #expect(e.stage == .ib)
    #expect(e.cause.hasPrefix("cannot read \(url.path)"))
}
