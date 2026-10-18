import Foundation

/// The indirect symbol table of an image `llvm-strip` rewrote (docs/react-native.md, "Known gaps"). An entry names a
/// symbol by its index in the symbol table, or is `INDIRECT_SYMBOL_LOCAL` / `INDIRECT_SYMBOL_ABS`. `ld64.lld` can leave
/// entries that name local symbols (a `GCC_except_table` label, say); `llvm-strip -S` drops those symbols, and the entry
/// it writes for a dropped symbol is bytes it never initialised: zero in an arm64 build of `llvm-strip`, 0x5555 in an
/// amd64 one. The same input then gives different bytes on the two host architectures. Apple's `strip` refuses such
/// an image (it says which symbols the indirect table still needs); Apple's linker marks an entry for a local symbol
/// `INDIRECT_SYMBOL_LOCAL`, which is what every dropped entry becomes here.
extension MachO {
    public static let indirectSymbolLocal: UInt32 = 0x8000_0000
    public static let indirectSymbolAbs: UInt32 = 0x4000_0000

    private struct SymbolTables {
        var keys: [String]            // per symbol index: name and value
        var indirectOffset: Int       // absolute, in the data it was read from
        var indirectCount: Int
    }

    private static func symbolTables(_ d: Data, slice r: Range<Int>) throws -> SymbolTables? {
        var symtab: (off: Int, n: Int, str: Int, strsize: Int)?
        var indirect: (off: Int, n: Int)?
        try forEachLoadCommand(d, slice: r) { off, cmd, size in
            switch cmd {
            case lcSymtab:
                guard size >= 24 else { throw MachOError.truncated }
                symtab = (Int(try d.u32(off + 8)), Int(try d.u32(off + 12)), Int(try d.u32(off + 16)), Int(try d.u32(off + 20)))
            case lcDysymtab:
                guard size >= 80 else { throw MachOError.truncated }
                indirect = (Int(try d.u32(off + 56)), Int(try d.u32(off + 60)))
            default: break
            }
        }
        guard let st = symtab, let ind = indirect, ind.n > 0 else { return nil }
        let base = r.lowerBound
        guard st.off >= 0, st.n >= 0, base + st.off + st.n * 16 <= r.upperBound,
              st.str >= 0, st.strsize >= 0, base + st.str + st.strsize <= r.upperBound,
              ind.off >= 0, base + ind.off + ind.n * 4 <= r.upperBound else { throw MachOError.truncated }
        var keys: [String] = []
        keys.reserveCapacity(st.n)
        for i in 0..<st.n {
            let e = base + st.off + i * 16
            let strx = Int(try d.u32(e))
            guard strx < st.strsize else { throw MachOError.truncated }
            let start = base + st.str + strx, end = base + st.str + st.strsize
            let stop = d[start..<end].firstIndex(of: 0) ?? end
            keys.append(String(decoding: d[start..<stop], as: UTF8.self) + "@" + String(try d.u64(e + 8)))
        }
        return SymbolTables(keys: keys, indirectOffset: base + ind.off, indirectCount: ind.n)
    }

    /// `stripped` (what `llvm-strip` wrote from `original`) with every indirect symbol table entry that named a symbol the
    /// strip dropped set to `INDIRECT_SYMBOL_LOCAL`, or nil when no entry needs it (also for archives and other data that
    /// is not a loadable image). Symbols are matched by name and value. Throws `MachOError` for a table outside its image.
    public static func normalizeStrippedIndirectSymbols(original: Data, stripped: Data) throws -> Data? {
        guard (try? containsLoadableImage(original)) == true, (try? containsLoadableImage(stripped)) == true else { return nil }
        let before = try slices(original), after = try slices(stripped)
        guard before.count == after.count else { return nil }
        var out = stripped
        var changed = false
        for (b, a) in zip(before, after) {
            guard let o = try symbolTables(original, slice: b), let s = try symbolTables(stripped, slice: a),
                  o.indirectCount == s.indirectCount else { continue }
            let kept = Set(s.keys)
            for i in 0..<s.indirectCount {
                let named = try original.u32(o.indirectOffset + 4 * i)
                guard named & (indirectSymbolLocal | indirectSymbolAbs) == 0, Int(named) < o.keys.count,
                      !kept.contains(o.keys[Int(named)]) else { continue }
                let at = s.indirectOffset + 4 * i
                if try out.u32(at) != indirectSymbolLocal {
                    try out.setU32LE(at, indirectSymbolLocal)
                    changed = true
                }
            }
        }
        return changed ? out : nil
    }
}
