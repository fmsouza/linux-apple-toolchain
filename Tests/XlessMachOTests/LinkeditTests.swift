import Testing
import Foundation
@testable import XlessMachO

/// A thin arm64 image laid out as `llvm-strip` leaves it: `__TEXT` (0..<0x4000), then `__LINKEDIT` holding function
/// starts (16 bytes), `nsyms` symbols, `nindirect` indirect symbols, the string pool right after them (4 bytes off when
/// `nindirect` is odd), then `gap` bytes and an optional code signature (16-aligned). `tail` is appended to `__LINKEDIT`.
struct LinkeditImage {
    var data = Data()
    var linkeditCmd = 0, symtabCmd = 0, dysymtabCmd = 0, sigCmd: Int?

    init(nsyms: Int = 3, nindirect: Int, strings: [UInt8] = Array("\0_main\0_helper\0\0".utf8), signature: Data? = nil,
         tail: Data = Data(), linkeditVMSize: UInt64? = nil, filetype: UInt32 = 6, extraCommands: [(UInt32, UInt32, UInt32)] = [],
         note: (offset: UInt64, size: UInt64)? = nil) {
        func u32(_ v: UInt32, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u64(_ v: UInt64, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func name16(_ s: String, _ d: inout Data) { d.append(contentsOf: Array(s.utf8)); d.append(Data(count: 16 - s.utf8.count)) }
        let leOff = 0x4000
        let fs = leOff, sym = fs + 16, ind = sym + nsyms * 16, str = ind + nindirect * 4
        var sig: Int?
        var end = str + strings.count
        if let signature { sig = (end + 15) & ~15; end = sig! + signature.count }
        end += tail.count
        var cmds = Data(), n: UInt32 = 0
        let header = 32
        func seg(_ name: String, vmaddr: UInt64, vmsize: UInt64, fileoff: Int, filesize: Int) -> Int {
            let at = header + cmds.count
            u32(0x19, &cmds); u32(72, &cmds); name16(name, &cmds)
            u64(vmaddr, &cmds); u64(vmsize, &cmds); u64(UInt64(fileoff), &cmds); u64(UInt64(filesize), &cmds)
            u32(1, &cmds); u32(1, &cmds); u32(0, &cmds); u32(0, &cmds); n += 1
            return at
        }
        _ = seg("__TEXT", vmaddr: 0, vmsize: UInt64(leOff), fileoff: 0, filesize: leOff)
        linkeditCmd = seg("__LINKEDIT", vmaddr: UInt64(leOff), vmsize: linkeditVMSize ?? 0x4000, fileoff: leOff, filesize: end - leOff)
        symtabCmd = header + cmds.count
        u32(0x2, &cmds); u32(24, &cmds); u32(UInt32(sym), &cmds); u32(UInt32(nsyms), &cmds); u32(UInt32(str), &cmds)
        u32(UInt32(strings.count), &cmds); n += 1
        dysymtabCmd = header + cmds.count
        u32(0xb, &cmds); u32(80, &cmds)
        for v in [0, 1, 1, 1, 2, UInt32(nsyms - 2), 0, 0, 0, 0, 0, 0, UInt32(ind), UInt32(nindirect), 0, 0, 0, 0] as [UInt32] { u32(v, &cmds) }
        n += 1
        u32(0x26, &cmds); u32(16, &cmds); u32(UInt32(fs), &cmds); u32(16, &cmds); n += 1
        u32(0x29, &cmds); u32(16, &cmds); u32(UInt32(str), &cmds); u32(0, &cmds); n += 1   // empty data in code at the pool
        if let sig, let signature {
            sigCmd = header + cmds.count
            u32(0x1d, &cmds); u32(16, &cmds); u32(UInt32(sig), &cmds); u32(UInt32(signature.count), &cmds); n += 1
        }
        for (cmd, off, size) in extraCommands { u32(cmd, &cmds); u32(16, &cmds); u32(off, &cmds); u32(size, &cmds); n += 1 }
        if let note { u32(0x31, &cmds); u32(40, &cmds); name16("owner", &cmds); u64(note.offset, &cmds); u64(note.size, &cmds); n += 1 }   // LC_NOTE
        u32(0xfeedfacf, &data); u32(0x0100000c, &data); u32(0, &data); u32(filetype, &data)
        u32(n, &data); u32(UInt32(cmds.count), &data); u32(0, &data); u32(0, &data)
        data.append(cmds)
        data.append(Data(count: leOff - data.count))
        data.append(Data(repeating: 0xf5, count: 16))                                  // function starts
        data.append(Data(repeating: 0x5e, count: nsyms * 16))                          // symbols
        for i in 0..<nindirect { u32(UInt32(i), &data) }                               // indirect symbols
        data.append(contentsOf: strings)
        if let sig, let signature { data.append(Data(count: sig - data.count)); data.append(signature) }
        data.append(tail)
    }
}

private func u32(_ d: Data, _ off: Int) -> Int { Int(try! d.u32(off)) }
private func u64(_ d: Data, _ off: Int) -> UInt64 { try! d.u64(off) }

@Test func alignsAMisalignedStringPoolAndMovesTheSignature() throws {
    let sig = Data((0..<40).map { UInt8($0) })
    let img = LinkeditImage(nindirect: 3, signature: sig)
    let before = img.data
    let stroff = u32(before, img.symtabCmd + 16)
    #expect(stroff % 8 == 4)
    #expect(try MachO.linkeditAlignmentProblems(in: before) == ["arm64: string pool at file offset 0x\(String(stroff, radix: 16)) is not 8-byte aligned"])

    let after = try MachO.alignLinkeditStringPool(in: before)
    let newStroff = u32(after, img.symtabCmd + 16), strsize = u32(after, img.symtabCmd + 20)
    #expect(newStroff == stroff + 4)
    #expect(after[newStroff..<(newStroff + strsize)] == before[stroff..<(stroff + strsize)])
    #expect(after[stroff..<newStroff].allSatisfy { $0 == 0 })
    // Tables before the pool stay where they were.
    #expect(after[0x4000..<stroff] == before[0x4000..<stroff])
    #expect(u32(after, img.symtabCmd + 8) == u32(before, img.symtabCmd + 8))
    #expect(u32(after, img.dysymtabCmd + 56) == u32(before, img.dysymtabCmd + 56))
    // The signature moves, stays 16-aligned and keeps its bytes.
    let sigOff = u32(after, img.sigCmd! + 8)
    #expect(sigOff % 16 == 0 && sigOff >= newStroff + strsize)
    #expect(after[sigOff..<(sigOff + sig.count)] == sig)
    #expect(u32(after, img.sigCmd! + 12) == sig.count)
    // __LINKEDIT covers the new tail; vmsize still covers it (no page crossed).
    #expect(u64(after, img.linkeditCmd + 48) == UInt64(after.count - 0x4000))
    #expect(u64(after, img.linkeditCmd + 32) == 0x4000)
    #expect(after.count % 8 == 0)
    #expect(try MachO.linkeditAlignmentProblems(in: after).isEmpty)
    // Idempotent.
    #expect(try MachO.alignLinkeditStringPool(in: after) == after)
}

@Test func alignsWithoutASignatureAndMovesEmptyTablesAtThePool() throws {
    let img = LinkeditImage(nindirect: 5)
    let after = try MachO.alignLinkeditStringPool(in: img.data)
    let stroff = u32(after, img.symtabCmd + 16)
    #expect(stroff % 8 == 0)
    #expect(after[stroff..<(stroff + 16)] == Data("\0_main\0_helper\0\0".utf8))
    let dataInCode = try MachO.linkeditBlobs(after).first { $0.name == "data in code" }!
    #expect(dataInCode.offset == stroff && dataInCode.size == 0)
    #expect(u64(after, img.linkeditCmd + 48) == UInt64(after.count - 0x4000))
    #expect(try MachO.linkeditAlignmentProblems(in: after).isEmpty)
}

@Test func alignedStringPoolIsLeftAlone() throws {
    let img = LinkeditImage(nindirect: 4, signature: Data(count: 32))
    #expect(u32(img.data, img.symtabCmd + 16) % 8 == 0)
    #expect(try MachO.alignLinkeditStringPool(in: img.data) == img.data)
    #expect(try MachO.linkeditAlignmentProblems(in: img.data).isEmpty)
    let object = LinkeditImage(nindirect: 3, filetype: 1)   // MH_OBJECT: never loaded by dyld
    #expect(try MachO.alignLinkeditStringPool(in: object.data) == object.data)
    #expect(try MachO.linkeditAlignmentProblems(in: object.data).isEmpty)
}

@Test func growsVMSizeToAPageWhenTheTailCrossesIt() throws {
    let probe = LinkeditImage(nindirect: 3)
    let filesize = UInt64(probe.data.count - 0x4000)
    let img = LinkeditImage(nindirect: 3, linkeditVMSize: filesize)   // vmsize == filesize, as ld64.lld writes it
    let after = try MachO.alignLinkeditStringPool(in: img.data)
    #expect(u64(after, img.linkeditCmd + 48) > filesize)
    #expect(u64(after, img.linkeditCmd + 32) == 0x4000)
}

@Test func refusesLayoutsItDoesNotUnderstand() throws {
    // Unknown bytes after the string pool.
    #expect(throws: MachOError.self) { try MachO.alignLinkeditStringPool(in: LinkeditImage(nindirect: 3, tail: Data([1, 2, 3, 4])).data) }
    #expect(throws: MachOError.self) {
        try MachO.alignLinkeditStringPool(in: LinkeditImage(nindirect: 3, signature: Data(count: 16), tail: Data([9])).data)
    }
    // A table other than the code signature after the pool (LC_DYLIB_CODE_SIGN_DRS over the tail).
    let probe = LinkeditImage(nindirect: 3)
    let drs = LinkeditImage(nindirect: 3, tail: Data(repeating: 7, count: 8), extraCommands: [(0x2b, UInt32(probe.data.count), 8)])
    #expect(throws: MachOError.self) { try MachO.alignLinkeditStringPool(in: drs.data) }
    // __LINKEDIT not ending the file.
    var trailing = LinkeditImage(nindirect: 3).data
    trailing.append(Data(count: 8))
    #expect(throws: MachOError.self) { try MachO.alignLinkeditStringPool(in: trailing) }
    // 32-bit images.
    var thin32 = LinkeditImage(nindirect: 3).data
    try thin32.setU32LE(0, 0xfeedface)
    #expect(throws: MachOError.unsupported("32-bit Mach-O")) { try MachO.alignLinkeditStringPool(in: thin32) }
}

@Test func alignsEachSliceOfAFatFile() throws {
    let bad = LinkeditImage(nindirect: 3, signature: Data(repeating: 0xcc, count: 24)), good = LinkeditImage(nindirect: 2)
    let fat = try MachO.makeFat([good.data, bad.data])
    #expect(try MachO.linkeditAlignmentProblems(in: fat).count == 1)
    let after = try MachO.alignLinkeditStringPool(in: fat)
    #expect(try MachO.linkeditAlignmentProblems(in: after).isEmpty)
    let slices = try MachO.sliceArchitectures(in: after)
    #expect(slices.count == 2 && slices.allSatisfy { $0.range.lowerBound % 0x4000 == 0 })
    #expect(Data(after[slices[0].range]) == good.data)
    #expect(Data(after[slices[1].range]) == (try MachO.alignLinkeditStringPool(in: bad.data)))
    #expect(try MachO.alignLinkeditStringPool(in: try MachO.makeFat([good.data, good.data])) == (try MachO.makeFat([good.data, good.data])))
}

@Test func validatorFlagsWhatDyldRefuses() throws {
    var img = LinkeditImage(nindirect: 4)
    #expect(try MachO.linkeditAlignmentProblems(in: img.data).isEmpty)
    // Function starts 4 bytes off; the indirect symbol table only 4-aligned (dyld wants 8 on 64-bit).
    let fsCmd = img.dysymtabCmd + 80
    try img.data.setU32LE(fsCmd + 8, 0x4004)
    try img.data.setU32LE(img.dysymtabCmd + 56, try img.data.u32(img.dysymtabCmd + 56) + 4)
    #expect(try MachO.linkeditAlignmentProblems(in: img.data) == [
        "arm64: indirect symbol table at file offset 0x4044 is not 8-byte aligned",
        "arm64: function starts at file offset 0x4004 is not 8-byte aligned",
    ])
    // Empty tables are not checked (dyld does not), nor are tables dyld does not check.
    var empty = LinkeditImage(nindirect: 0, extraCommands: [(0x2e, 0x4003, 4)])
    try empty.data.setU32LE(empty.dysymtabCmd + 56, 0x4002)
    #expect(try MachO.linkeditAlignmentProblems(in: empty.data).isEmpty)
}

@Test func anEmptyNoteAtOrAfterTheStringPoolIsRefusedNotTruncated() throws {
    // LC_NOTE's offset is a 64-bit field the re-layout does not rewrite: refused as unsupported (it was `.truncated`).
    let stroff = UInt64(u32(LinkeditImage(nindirect: 3).data, LinkeditImage(nindirect: 3).symtabCmd + 16))
    let atPool = LinkeditImage(nindirect: 3, note: (stroff, 0))
    #expect(throws: MachOError.unsupported("an empty note at file offset \(stroff), at or after the string pool")) {
        try MachO.alignLinkeditStringPool(in: atPool.data)
    }
    // Before the pool it stays where it is, and the pool is aligned.
    let before = LinkeditImage(nindirect: 3, note: (0x4000, 0))
    let after = try MachO.alignLinkeditStringPool(in: before.data)
    #expect(try MachO.linkeditAlignmentProblems(in: after).isEmpty)
    #expect(try MachO.linkeditBlobs(after).first { $0.name == "note" }?.offset == 0x4000)
}
