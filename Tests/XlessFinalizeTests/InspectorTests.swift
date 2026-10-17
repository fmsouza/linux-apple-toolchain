import Testing
import Foundation
@testable import XlessFinalize
@testable import XlessCore
import XlessMachO

@Test func reportsPlistAndBinaries() throws {
    let app = try iosApp()
    let r = try Inspector.report(bundle: app, platform: .ios)
    #expect(r.infoPlist["CFBundleExecutable"] == "X")
    #expect(r.binaries.map(\.path) == ["X"])
    #expect(r.binaries[0].buildVersions == ["platform=2 minos=17.0 sdk=17.0"])
    #expect(r.binaries[0].linkeditProblems.isEmpty)
}

@Test func reportsMisalignedLinkedit() throws {
    let app = try iosApp(extraFiles: ["Frameworks/J.framework/J": binaryWithStringPool(at: 84)])
    let r = try Inspector.report(bundle: app, platform: .ios)
    #expect(r.binaries.first { $0.path == "Frameworks/J.framework/J" }?.linkeditProblems
            == ["arm64: string pool at file offset 0x54 is not 8-byte aligned"])
}

@Test func reportsAMalformedLinkeditInsteadOfThrowing() throws {
    // LC_SYMTAB with a 16-byte cmdsize (it needs 24): the build versions read, the LINKEDIT tables do not.
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    u32(0xfeedfacf); u32(0x0100000c); u32(0); u32(6); u32(2); u32(40); u32(0); u32(0)
    u32(0x32); u32(24); u32(2); u32(try MachO.encodeVersion("17.0")); u32(try MachO.encodeVersion("17.0")); u32(0)
    u32(0x2); u32(16); u32(0); u32(0)
    let app = try iosApp(extraFiles: ["Frameworks/M.framework/M": d + Data(count: 16)])
    let r = try Inspector.report(bundle: app, platform: .ios)
    let m = try #require(r.binaries.first { $0.path == "Frameworks/M.framework/M" })
    #expect(m.buildVersions == ["platform=2 minos=17.0 sdk=17.0"])
    #expect(m.linkeditProblems.count == 1 && m.linkeditProblems[0].hasPrefix("malformed LINKEDIT: "))
}
