import Testing
import Foundation
@testable import XlessMachO

/// Minimal thin MH_MAGIC_64 file: header + LC_UUID + LC_BUILD_VERSION.
func thin(cpu: UInt32 = 0x0100000c, platform: UInt32 = 2, minos: String = "17.0", sdk: String = "17.0") throws -> Data {
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    u32(0xfeedfacf); u32(cpu); u32(0); u32(2 /*MH_EXECUTE*/); u32(2 /*ncmds*/); u32(48); u32(0); u32(0)
    u32(0x1b); u32(24); d.append(Data(repeating: 0xab, count: 16))           // LC_UUID
    u32(0x32); u32(24); u32(platform); u32(try MachO.encodeVersion(minos)); u32(try MachO.encodeVersion(sdk)); u32(0)
    d.append(Data(repeating: 0, count: 64))
    return d
}

@Test(arguments: [("27.0", UInt32(0x1b0000)), ("17.4", UInt32(0x110400)), ("14.0.1", UInt32(0x0e0001))])
func encodesVersions(s: String, v: UInt32) throws {
    #expect(try MachO.encodeVersion(s) == v)
    #expect(MachO.decodeVersion(v) == s)
}

@Test func readsAndPatchesThin() throws {
    var d = try thin()
    #expect(MachO.isMachO(d))
    #expect(try MachO.buildVersions(in: d) == [BuildVersion(cpuType: 0x0100000c, platform: 2, minos: 0x110000, sdk: 0x110000)])
    #expect(try MachO.patchSDK(in: &d, to: MachO.encodeVersion("27.0")) == 1)
    #expect(try MachO.buildVersions(in: d).first?.sdk == 0x1b0000)
    #expect(try MachO.buildVersions(in: d).first?.minos == 0x110000)
}

@Test func mergesAndPatchesFat() throws {
    let arm = try thin(cpu: 0x0100000c, platform: 1, minos: "14.0", sdk: "14.0")
    let x86 = try thin(cpu: 0x01000007, platform: 1, minos: "14.0", sdk: "14.0")
    var fat = try MachO.makeFat([arm, x86])
    #expect(MachO.isMachO(fat))
    #expect(try MachO.buildVersions(in: fat).map(\.cpuType) == [0x0100000c, 0x01000007])
    #expect(try MachO.patchSDK(in: &fat, to: MachO.encodeVersion("27.0")) == 2)
    #expect(try MachO.buildVersions(in: fat).allSatisfy { $0.sdk == 0x1b0000 })
}

@Test func rejectsNonMachO() {
    #expect(!MachO.isMachO(Data("hello world".utf8)))
    #expect(throws: MachOError.self) { try MachO.buildVersions(in: Data("hello world".utf8)) }
    #expect(throws: MachOError.self) { try MachO.buildVersions(in: Data([0xcf, 0xfa])) }
}

@Test func rejectsMalformedBuildVersionCommand() throws {
    var d = try thin()
    d.removeLast(64)
    d.removeLast(16)                       // drop sdk/ntools tail; command now ends at 8 bytes
    d.removeLast(8)
    // d now ends right after LC_UUID; append trailing LC_BUILD_VERSION with cmdsize 8
    var tail = Data()
    for v in [UInt32(0x32), 8] { var x = v.littleEndian; withUnsafeBytes(of: &x) { tail.append(contentsOf: $0) } }
    d.append(tail)
    let before = d
    #expect(throws: MachOError.self) { try MachO.buildVersions(in: d) }
    #expect(throws: MachOError.self) { try MachO.patchSDK(in: &d, to: 0x1b0000) }
    #expect(d == before)
}

@Test func rejectsSliceBeyondData() throws {
    var fat = try MachO.makeFat([try thin()])
    fat.removeLast(100)
    #expect(throws: MachOError.self) { try MachO.buildVersions(in: fat) }
}

@Test func rejectsShortSlice() throws {
    #expect(throws: MachOError.self) { try MachO.buildVersions(in: try thin().prefix(20)) }
    var fat = try MachO.makeFat([try thin()])
    // shrink the declared slice size to 20 bytes
    var sz = UInt32(20).bigEndian
    withUnsafeBytes(of: &sz) { fat.replaceSubrange(20..<24, with: $0) }
    #expect(throws: MachOError.self) { try MachO.buildVersions(in: fat) }
}

/// "!<arch>\n" plus one minimal member header, as in a static library.
func arArchive() -> Data {
    var d = Data("!<arch>\n".utf8)
    d.append(Data("x.o/            0           0     0     100644  4         `\nabcd".utf8))
    return d
}

/// Fat wrapper (cafebabe) around raw slices, each tagged arm64.
func fatWrap(_ slices: [Data]) -> Data {
    var out = Data()
    func be(_ v: UInt32) { var x = v.bigEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
    be(0xcafebabe); be(UInt32(slices.count))
    var off = 8 + 20 * slices.count
    var placed: [(Int, Data)] = []
    for s in slices {
        off = (off + 0x3fff) & ~0x3fff
        be(0x0100000c); be(0); be(UInt32(off)); be(UInt32(s.count)); be(14)
        placed.append((off, s)); off += s.count
    }
    for (o, s) in placed { out.append(Data(count: o - out.count)); out.append(s) }
    return out
}

@Test func classifiesImagesAndArchives() throws {
    #expect(try MachO.containsLoadableImage(try thin()))
    #expect(try MachO.containsLoadableImage(try MachO.makeFat([try thin(), try thin(cpu: 0x01000007)])))
    #expect(try !MachO.containsLoadableImage(arArchive()))
    #expect(try !MachO.containsLoadableImage(fatWrap([arArchive()])))
    #expect(try !MachO.containsLoadableImage(Data("hello world".utf8)))
    #expect(try !MachO.containsLoadableImage(Data([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 52, 1, 2])))   // Java class file
}

@Test func mixedFatIsAnError() throws {
    let mixed = fatWrap([try thin(), arArchive()])
    #expect(throws: MachOError.self) { try MachO.containsLoadableImage(mixed) }
}
