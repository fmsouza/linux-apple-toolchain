import Foundation
import XlessCore

public enum Varint {
    /// NIB varints: 7-bit little-endian groups; the byte with the high bit set terminates.
    public static func encode(_ value: Int) -> [UInt8] {
        precondition(value >= 0)
        var v = value, out: [UInt8] = []
        repeat {
            let low = UInt8(v & 0x7F)
            v >>= 7
            out.append(v == 0 ? (low | 0x80) : low)
        } while v != 0
        return out
    }

    public static func decode(_ data: Data, at i: inout Int) throws -> Int {
        let start = i
        var value = 0, shift = 0
        while true {
            guard i >= 0, i < data.count else {
                throw XlessError(.ib, "truncated NIB varint at byte \(start)", fix: "the .nib file is corrupt")
            }
            let b = data[data.startIndex + i]; i += 1
            let group = Int(b & 0x7F)
            if group != 0 {
                guard shift < 31, (group << shift) <= Int(Int32.max) else {
                    throw XlessError(.ib, "NIB varint overflow at byte \(start)", fix: "the .nib file is corrupt")
                }
                value |= group << shift
            } else if shift >= 63 {
                throw XlessError(.ib, "NIB varint overflow at byte \(start)", fix: "the .nib file is corrupt")
            }
            shift += 7
            if b & 0x80 != 0 {
                guard value <= Int(Int32.max) else {
                    throw XlessError(.ib, "NIB varint overflow at byte \(start)", fix: "the .nib file is corrupt")
                }
                return value
            }
        }
    }
}
