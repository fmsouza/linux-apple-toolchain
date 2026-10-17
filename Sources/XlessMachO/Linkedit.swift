import Foundation

extension Data {
    func u64(_ off: Int) throws -> UInt64 {
        guard off >= 0, off + 8 <= count else { throw MachOError.truncated }
        return UInt64(littleEndian: withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt64.self) })
    }

    mutating func setU64LE(_ off: Int, _ value: UInt64) throws {
        guard off >= 0, off + 8 <= count else { throw MachOError.truncated }
        withUnsafeMutableBytes { $0.storeBytes(of: value.littleEndian, toByteOffset: off, as: UInt64.self) }
    }
}

/// One table or blob in `__LINKEDIT` that a load command points at (offsets are slice-relative, as in the file).
struct LinkeditBlob: Equatable {
    var name: String
    var offset: Int
    var size: Int
    /// Position of the command's 32-bit offset field, relative to the slice.
    var field: Int
    /// dyld refuses the image when this blob, non-empty, is not pointer-aligned.
    var dyldChecksAlignment: Bool
}

/// `__LINKEDIT` alignment (docs/react-native.md, "Known gaps"). dyld refuses to load an image whose LINKEDIT tables are
/// not pointer-aligned ("mis-aligned LINKEDIT string pool", "mis-aligned LINKEDIT content '…'"). Which tables it checks
/// was learned black-box with `dyld_info -validate_only` on deliberately misaligned copies of real images: on 64-bit,
/// each non-empty table marked checked below must start on an 8-byte boundary (4 is refused, the indirect symbol table
/// included); empty tables and the string pool's size are not checked. Apple's linker and strip keep that layout;
/// LLVM 21's `llvm-strip` puts the string pool right after the indirect symbol table (4-byte entries), so an odd
/// indirect symbol count leaves it 4 bytes off.
extension MachO {
    static let lcSegment64: UInt32 = 0x19
    static let lcSymtab: UInt32 = 0x2
    static let lcDysymtab: UInt32 = 0xb
    static let lcCodeSignature: UInt32 = 0x1d
    static let mhObject: UInt32 = 1
    static let linkeditPointerAlignment = 8

    /// linkedit_data_command types: name, and whether dyld checks the blob's alignment (measured; see above).
    static let linkeditDataCommands: [UInt32: (String, Bool)] = [
        0x1d: ("code signature", true), 0x1e: ("segment split info", false), 0x26: ("function starts", true),
        0x29: ("data in code", true), 0x2b: ("dylib code sign DRs", false), 0x2e: ("linker optimization hint", false),
        0x8000_0033: ("exports trie", true), 0x8000_0034: ("chained fixups", true), 0x36: ("atom info", false),
    ]

    /// Every LINKEDIT reference of a thin 64-bit image (`d` is the slice alone).
    static func linkeditBlobs(_ d: Data) throws -> [LinkeditBlob] {
        var out: [LinkeditBlob] = []
        func add(_ name: String, _ cmd: Int, _ offField: Int, size: Int, checked: Bool) throws {
            out.append(LinkeditBlob(name: name, offset: Int(try d.u32(cmd + offField)), size: size, field: cmd + offField,
                                    dyldChecksAlignment: checked))
        }
        func count(_ at: Int) throws -> Int { Int(try d.u32(at)) }
        try forEachLoadCommand(d, slice: 0..<d.count) { off, cmd, size in
            func need(_ n: Int) throws { guard size >= n else { throw MachOError.truncated } }
            switch cmd {
            case lcSymtab:
                try need(24)
                try add("symbol table", off, 8, size: try count(off + 12) * 16, checked: true)
                try add("string pool", off, 16, size: try count(off + 20), checked: true)
            case lcDysymtab:
                try need(80)
                try add("table of contents", off, 32, size: try count(off + 36) * 8, checked: false)
                try add("module table", off, 40, size: try count(off + 44) * 56, checked: false)
                try add("external reference table", off, 48, size: try count(off + 52) * 4, checked: false)
                try add("indirect symbol table", off, 56, size: try count(off + 60) * 4, checked: true)
                try add("external relocations", off, 64, size: try count(off + 68) * 8, checked: false)
                try add("local relocations", off, 72, size: try count(off + 76) * 8, checked: false)
            case 0x22, 0x8000_0022:   // LC_DYLD_INFO(_ONLY)
                try need(48)
                try add("rebase opcodes", off, 8, size: try count(off + 12), checked: true)
                try add("bind opcodes", off, 16, size: try count(off + 20), checked: true)
                try add("weak bind opcodes", off, 24, size: try count(off + 28), checked: false)
                try add("lazy bind opcodes", off, 32, size: try count(off + 36), checked: true)
                try add("export info", off, 40, size: try count(off + 44), checked: true)
            case 0x16:   // LC_TWOLEVEL_HINTS
                try need(16)
                try add("two-level hints", off, 8, size: try count(off + 12) * 4, checked: false)
            case 0x31:   // LC_NOTE: 64-bit offset and size
                try need(40)
                let o = try d.u64(off + 24), s = try d.u64(off + 32)
                guard o <= UInt64(Int32.max), s <= UInt64(Int32.max) else { throw MachOError.unsupported("LC_NOTE beyond 2 GiB") }
                out.append(LinkeditBlob(name: "note", offset: Int(o), size: Int(s), field: -1, dyldChecksAlignment: false))
            default:
                if let (name, checked) = linkeditDataCommands[cmd] {
                    try need(16)
                    try add(name, off, 8, size: try count(off + 12), checked: checked)
                }
            }
        }
        return out
    }

    /// The tables dyld would refuse as mis-aligned, per slice ("arm64: string pool at file offset 0x7941c is not 8-byte
    /// aligned"). Object files (never loaded by dyld) and non-Mach-O data have none; 32-bit images are not supported.
    public static func linkeditAlignmentProblems(in data: Data) throws -> [String] {
        var out: [String] = []
        for (_, arch, r) in try sliceArchitectures(in: data) {
            let d = Data(data[r])
            guard r.count >= 32, try d.u32(12) != mhObject else { continue }
            for b in try linkeditBlobs(d) where b.dyldChecksAlignment && b.size > 0 && b.offset % linkeditPointerAlignment != 0 {
                out.append("\(arch): \(b.name) at file offset 0x\(String(b.offset, radix: 16)) is not \(linkeditPointerAlignment)-byte aligned")
            }
        }
        return out
    }

    /// Re-lays the tail of `__LINKEDIT` so the string pool starts on an 8-byte boundary, as Apple's linker and strip
    /// leave it: zero padding goes before the string pool, `LC_SYMTAB.stroff` and everything after it move (in an
    /// `llvm-strip` output that is only the code signature, which stays 16-byte aligned as both linkers write it; its
    /// contents are then stale, which is harmless because the sign stage re-signs every image), and `__LINKEDIT`'s
    /// `filesize` (and `vmsize`, past a page) grows. Fat files are re-laid per slice and re-wrapped with each slice's
    /// alignment. Returns `data` unchanged when the pool is already aligned, and for object files (no `__LINKEDIT`;
    /// dyld never loads them). `strsize` is kept: dyld does not check it (measured).
    /// Throws `MachOError.unsupported` for a layout it does not understand: a 32-bit image, `__LINKEDIT` not last in
    /// the file, or anything after the string pool but a code signature and zero padding.
    public static func alignLinkeditStringPool(in data: Data) throws -> Data {
        guard isFat(data) else { return try alignStringPoolThin(data) }
        let n = Int(try data.u32(4, bigEndian: true))
        let ranges = try slices(data)
        let relaid = try ranges.map { try alignStringPoolThin(Data(data[$0])) }
        if zip(ranges, relaid).allSatisfy({ $0.count == $1.count && data[$0] == $1 }) { return data }
        var out = Data(data.prefix(8 + 20 * n))
        var cursor = out.count
        for (i, slice) in relaid.enumerated() {
            let entry = 8 + 20 * i
            let align = try data.u32(entry + 16, bigEndian: true)
            guard align <= 16 else { throw MachOError.unsupported("fat slice alignment 2^\(align)") }
            let a = 1 << Int(align)
            cursor = (cursor + a - 1) & ~(a - 1)
            out.append(Data(count: cursor - out.count))
            withUnsafeBytes(of: UInt32(cursor).bigEndian) { out.replaceSubrange((entry + 8)..<(entry + 12), with: $0) }
            withUnsafeBytes(of: UInt32(slice.count).bigEndian) { out.replaceSubrange((entry + 12)..<(entry + 16), with: $0) }
            out.append(slice)
            cursor = out.count
        }
        return out
    }

    static func alignStringPoolThin(_ d: Data) throws -> Data {
        guard d.count >= 32 else { throw MachOError.truncated }
        guard try d.u32(0) == mhMagic64 else {
            throw (try? d.u32(0)) == mhMagic32 ? MachOError.unsupported("32-bit Mach-O") : MachOError.notMachO
        }
        guard try d.u32(12) != mhObject else { return d }
        let blobs = try linkeditBlobs(d)
        guard let pool = blobs.first(where: { $0.name == "string pool" }), pool.size > 0,
              pool.offset % linkeditPointerAlignment != 0 else { return d }

        var linkedit: (cmd: Int, vmaddr: UInt64, vmsize: UInt64, fileoff: Int, filesize: Int)?
        var others: [(vmEnd: UInt64, fileEnd: Int)] = []
        try forEachLoadCommand(d, slice: 0..<d.count) { off, cmd, size in
            guard cmd == lcSegment64 else { return }
            guard size >= 72 else { throw MachOError.truncated }
            let name = String(decoding: d[(off + 8)..<(off + 24)].prefix { $0 != 0 }, as: UTF8.self)
            let vmaddr = try d.u64(off + 24), vmsize = try d.u64(off + 32)
            let fileoff = Int(try d.u64(off + 40)), filesize = Int(try d.u64(off + 48))
            if name == "__LINKEDIT" {
                guard linkedit == nil else { throw MachOError.unsupported("two __LINKEDIT segments") }
                guard try d.u32(off + 64) == 0 else { throw MachOError.unsupported("__LINKEDIT has sections") }
                linkedit = (off, vmaddr, vmsize, fileoff, filesize)
            } else {
                others.append((vmaddr + vmsize, fileoff + filesize))
            }
        }
        guard let le = linkedit else { throw MachOError.unsupported("a string pool but no __LINKEDIT segment") }
        let end = le.fileoff + le.filesize
        guard end == d.count else { throw MachOError.unsupported("__LINKEDIT does not end the file (\(end) of \(d.count) bytes)") }
        guard others.allSatisfy({ $0.fileEnd <= le.fileoff && $0.vmEnd <= le.vmaddr }) else {
            throw MachOError.unsupported("__LINKEDIT is not the last segment")
        }
        let poolEnd = pool.offset + pool.size
        guard pool.offset >= le.fileoff, poolEnd <= end else { throw MachOError.unsupported("the string pool is outside __LINKEDIT") }

        // After the pool: only a code signature and zero padding; empty references there just move with it.
        var signature: LinkeditBlob?
        var moved: [LinkeditBlob] = []
        for b in blobs where b != pool {
            if b.size == 0 {
                guard b.offset >= pool.offset else { continue }
                // Only 32-bit offset fields are rewritten (an LC_NOTE's is 64-bit and has no `field`).
                guard b.field >= 0 else { throw MachOError.unsupported("an empty \(b.name) at file offset \(b.offset), at or after the string pool") }
                moved.append(b)
                continue
            }
            if b.offset + b.size <= pool.offset { continue }
            guard b.name == "code signature", b.offset >= poolEnd, b.offset + b.size <= end, signature == nil else {
                throw MachOError.unsupported("\(b.name) at file offset \(b.offset) overlaps or follows the string pool")
            }
            signature = b
        }
        let gapEnd = signature?.offset ?? end
        guard d[poolEnd..<gapEnd].allSatisfy({ $0 == 0 }), d[(signature.map { $0.offset + $0.size } ?? end)..<end].allSatisfy({ $0 == 0 }) else {
            throw MachOError.unsupported("unknown data after the string pool")
        }

        func up(_ v: Int, _ a: Int) -> Int { (v + a - 1) & ~(a - 1) }
        let newPool = up(pool.offset, linkeditPointerAlignment)
        let delta = newPool - pool.offset
        var out = Data(d.prefix(pool.offset))
        out.append(Data(count: delta))
        out.append(d[pool.offset..<poolEnd])
        if let sig = signature {
            out.append(Data(count: up(out.count, 16) - out.count))
            try out.setU32LE(sig.field, UInt32(out.count))
            out.append(d[sig.offset..<(sig.offset + sig.size)])
        }
        out.append(Data(count: up(out.count, linkeditPointerAlignment) - out.count))
        try out.setU32LE(pool.field, UInt32(newPool))
        for b in moved { try out.setU32LE(b.field, UInt32(min(b.offset + delta, out.count))) }

        let filesize = out.count - le.fileoff
        try out.setU64LE(le.cmd + 48, UInt64(filesize))
        if UInt64(filesize) > le.vmsize {
            let page: UInt64 = try d.u32(4) == 0x0100000c ? 0x4000 : 0x1000
            try out.setU64LE(le.cmd + 32, (UInt64(filesize) + page - 1) & ~(page - 1))
        }
        return out
    }
}
