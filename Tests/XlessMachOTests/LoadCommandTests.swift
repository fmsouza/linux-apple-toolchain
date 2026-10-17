import Testing
import Foundation
@testable import XlessMachO

/// Thin MH_MAGIC_64 file with LC_LOAD_DYLIB / LC_RPATH commands (string commands padded to 8 bytes).
func thinWithLibs(dylibs: [String], rpaths: [String], weak: [String] = []) -> Data {
    var cmds = Data()
    func u32(_ v: UInt32, _ d: inout Data) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    func strCmd(_ cmd: UInt32, _ name: String, dylib: Bool) {
        let nameOff: UInt32 = dylib ? 24 : 12
        let size = (Int(nameOff) + name.utf8.count + 1 + 7) & ~7
        u32(cmd, &cmds); u32(UInt32(size), &cmds); u32(nameOff, &cmds)
        if dylib { u32(2, &cmds); u32(0x10000, &cmds); u32(0x10000, &cmds) }
        cmds.append(contentsOf: Array(name.utf8)); cmds.append(Data(repeating: 0, count: size - Int(nameOff) - name.utf8.count))
    }
    for d in dylibs { strCmd(0xc, d, dylib: true) }
    for d in weak { strCmd(0x80000018, d, dylib: true) }
    for r in rpaths { strCmd(0x8000001c, r, dylib: false) }
    var d = Data()
    u32(0xfeedfacf, &d); u32(0x0100000c, &d); u32(0, &d); u32(2, &d)
    u32(UInt32(dylibs.count + weak.count + rpaths.count), &d); u32(UInt32(cmds.count), &d); u32(0, &d); u32(0, &d)
    return d + cmds
}

@Test func readsLinkedLibrariesAndRpaths() throws {
    let d = thinWithLibs(dylibs: ["/usr/lib/libSystem.B.dylib", "@rpath/onnxruntime.framework/onnxruntime"],
                         rpaths: ["@executable_path/Frameworks"])
    #expect(try MachO.linkedLibraries(in: d) == ["/usr/lib/libSystem.B.dylib", "@rpath/onnxruntime.framework/onnxruntime"])
    #expect(try MachO.rpaths(in: d) == ["@executable_path/Frameworks"])
}

@Test func includesWeakDylibs() throws {
    let d = thinWithLibs(dylibs: ["/a"], rpaths: [], weak: ["/b"])
    #expect(try MachO.linkedLibraries(in: d) == ["/a", "/b"])
    #expect(try MachO.rpaths(in: d) == [])
}

@Test func fatUsesFirstSlice() throws {
    let a = thinWithLibs(dylibs: ["/first"], rpaths: [])
    let b = thinWithLibs(dylibs: ["/second"], rpaths: [])
    #expect(try MachO.linkedLibraries(in: MachO.makeFat([a, b])) == ["/first"])
}

@Test func loadCommandParsingRejectsGarbage() {
    #expect(throws: MachOError.self) { try MachO.linkedLibraries(in: Data("hello world".utf8)) }
    var d = thinWithLibs(dylibs: ["/usr/lib/libSystem.B.dylib"], rpaths: [])
    d.removeLast(8)
    #expect(throws: MachOError.self) { try MachO.linkedLibraries(in: d) }
}

@Test func loadCommandTypesListEverySliceInOrder() throws {
    let a = thinWithLibs(dylibs: ["/usr/lib/libSystem.B.dylib"], rpaths: ["@executable_path/Frameworks"])
    let b = thinWithLibs(dylibs: [], rpaths: [], weak: ["/usr/lib/libz.dylib"])
    #expect(try MachO.loadCommandTypes(in: a) == [0xc, 0x8000001c])
    #expect(try MachO.loadCommandTypes(in: try MachO.makeFat([a, b])) == [0xc, 0x8000001c, 0x80000018])
    #expect(throws: MachOError.self) { try MachO.loadCommandTypes(in: a.prefix(40)) }
}
