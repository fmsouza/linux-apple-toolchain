import Testing
import Foundation
import XlessCore
@testable import XlessIB

private func keyNames(_ a: NIBArchive) -> [String] { a.keys.map { String(decoding: $0, as: UTF8.self) } }

@Test func builderInternsKeysAndClassNames() throws {
    let b = ArchiveBuilder()
    let root = b.object("NSObject")
    let s1 = b.object("NSString"), s2 = b.object("NSString")
    b.set(s1, "NS.bytes", .data(Data("a".utf8)))
    b.set(s2, "NS.bytes", .data(Data("b".utf8)))
    b.set(root, "A", s1)
    b.set(root, "B", s2)
    let a = try b.finish(root: root)
    #expect(a.classNames.map(\.string) == ["NSObject", "NSString"])
    #expect(Set(keyNames(a)) == ["A", "B", "NS.bytes"])
    #expect(a.keys.count == 3)
    #expect(a.values.filter { keyNames(a)[$0.keyIndex] == "NS.bytes" }.count == 2)
}

@Test func builderNumbersObjectsInCreationOrderForTopDownTrees() throws {
    let b = ArchiveBuilder()
    let root = b.object("NSObject")
    let arr = b.object("NSArray")
    b.set(root, "list", arr)
    b.set(arr, "NSInlinedValue", .bool(true))
    let x = b.object("NSString"); b.set(arr, "UINibEncoderEmptyKey", x); b.set(x, "NS.bytes", .data(Data("x".utf8)))
    let y = b.object("NSString"); b.set(arr, "UINibEncoderEmptyKey", y); b.set(y, "NS.bytes", .data(Data("y".utf8)))
    b.set(root, "flag", .int8(1))
    let a = try b.finish(root: root)
    #expect(a.objects.count == 4)
    // values are contiguous per object, in object order
    var next = 0
    for o in a.objects { #expect(o.valuesStart == next); next += o.valueCount }
    #expect(next == a.values.count)
    #expect(a.objects.map(\.valueCount) == [2, 3, 1, 1])
    #expect(a.values[a.objects[0].valuesStart].data == .object(1))
    #expect(a.values[a.objects[1].valuesStart + 1].data == .object(2))
    #expect(a.values[a.objects[1].valuesStart + 2].data == .object(3))
}

@Test func builderNumbersByDepthFirstFirstReferenceNotCreationOrder() throws {
    // Section 3: an object gets its number the first time a value refers to it, walking depth-first.
    let b = ArchiveBuilder()
    let leaf = b.object("NSString"); b.set(leaf, "NS.bytes", .data(Data("leaf".utf8)))
    let root = b.object("NSObject")
    let mid = b.object("NSArray")
    b.set(root, "first", mid)
    b.set(mid, "UINibEncoderEmptyKey", leaf)
    b.set(root, "second", leaf)
    let a = try b.finish(root: root)
    #expect(a.classNames.map(\.string) == ["NSObject", "NSArray", "NSString"])
    #expect(a.values[a.objects[0].valuesStart + 1].data == .object(2))   // "second" points at the shared leaf (#2)
}

@Test func builderUniquesValueObjects() throws {
    let b = ArchiveBuilder()
    let root = b.object("NSObject")
    b.set(root, "a", b.string("same"))
    b.set(root, "b", b.string("same"))
    b.set(root, "c", b.string("other"))
    let a = try b.finish(root: root)
    #expect(a.objects.count == 3)
}

@Test func builderAppendsFallbackClassesWithExtras() throws {
    let b = ArchiveBuilder()
    let root = b.object("NSObject")
    let c = b.object("UIColor", fallback: "NSColor")
    b.set(root, "color", c)
    b.set(c, "UIColorComponentCount", .int8(2))
    let a = try b.finish(root: root)
    #expect(a.classNames.map(\.string) == ["NSObject", "UIColor", "NSColor"])
    #expect(a.classNames[1].extras == [2])
    #expect(a.classNames[0].extras.isEmpty && a.classNames[2].extras.isEmpty)
}

@Test func keyTableFollowsCFHashOrderInEveryGoldenNib() throws {
    // Every golden's key table is the hash-table enumeration order of its keys in first-use order
    // (including the capacity boundaries keys-count-86/87/90 and the 191-bucket table up to keys-count-107).
    let nibs = try goldenNibs()
    #expect(nibs.contains { $0.path.contains("/keys-count-90/") })
    #expect(nibs.contains { $0.path.contains("/keys-count-107/") })
    for url in nibs {
        let golden = try NIBArchiveReader.read(Data(contentsOf: url))
        let names = keyNames(golden)
        // insertion order = first use in depth-first value order
        var seen: [String] = []
        var visited = Set<Int>([0])
        func walk(_ i: Int) {
            let o = golden.objects[i]
            for v in golden.values[o.valuesStart..<(o.valuesStart + o.valueCount)] {
                let k = names[v.keyIndex]
                if !seen.contains(k) { seen.append(k) }
                if case .object(let r) = v.data, visited.insert(Int(r)).inserted { walk(Int(r)) }
            }
        }
        walk(0)
        #expect(try ArchiveBuilder.keyTableOrder(seen) == names, "\(url.path)")
    }
}

@Test func keyTablesAboveTheVerifiedSizeAreRefused() throws {
    #expect(ArchiveBuilder.maxVerifiedKeyCount == 107)
    _ = try ArchiveBuilder.keyTableOrder((0..<107).map { "k\($0)" })
    let keys = (0..<108).map { "k\($0)" }
    let e = try #require(throws: XlessError.self) { try ArchiveBuilder.keyTableOrder(keys) }
    #expect(e.cause.hasPrefix("unsupported: 108 distinct NIB keys"))
}

/// The `keys-count-N` corpus cases have N keys (their names are the evidence nib-encoding.md cites).
@Test func keysCountCasesHaveTheirKeyCount() throws {
    var seen = 0
    for url in try goldenNibs() where url.path.contains("/keys-count-") && url.lastPathComponent.contains("-view-") {
        let name = url.pathComponents.first { $0.hasPrefix("keys-count-") }!
        guard let n = Int(name.dropFirst("keys-count-".count)) else { continue }
        #expect(try NIBArchiveReader.read(Data(contentsOf: url)).keys.count == n, "\(url.path)")
        seen += 1
    }
    #expect(seen >= 16)
}

@Test func integerValuesUseSmallestObservedWidth() throws {
    #expect(try ArchiveBuilder.int(0) == .int8(0))
    #expect(try ArchiveBuilder.int(127) == .int8(127))
    #expect(try ArchiveBuilder.int(128) == .int16(128))
    #expect(try ArchiveBuilder.int(32767) == .int16(32767))
    #expect(try ArchiveBuilder.int(-1) == .int64(-1))
    #expect(try ArchiveBuilder.int(2147517444) == .int64(2147517444))
}

/// Open question 9, resolved in m3 Task 6b: 32768…2^31-1 are int32 (`acc-traits-grid`: 65536, 65540, 98303;
/// scratch runs: 32768, 40000, 2^31-1), 2^31 is int64.
@Test func int32WidthCoversTheInt32Range() throws {
    #expect(try ArchiveBuilder.int(32768) == .int32(32768))
    #expect(try ArchiveBuilder.int(65536) == .int32(65536))
    #expect(try ArchiveBuilder.int(Int(Int32.max)) == .int32(Int32.max))
    #expect(try ArchiveBuilder.int(Int(Int32.max) + 1) == .int64(Int64(Int32.max) + 1))
}
