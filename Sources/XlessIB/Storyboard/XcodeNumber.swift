import Foundation

/// Numbers in the spelling Xcode writes (final review I2). ibtool reads other spellings its own way (`pointSize="0x11"`
/// gives 12 and `red="0x1"` gives 0, where `Double("0x11")` is 17), so every numeric attribute goes through here.
enum XcodeNumber {
    /// `[-](0|[1-9][0-9]*)[.[0-9]+]` as a finite double; a negative zero ("-0.0") only with `negativeZero` (constraint
    /// constants: `cons-values-grid`). With `exponent`,
    /// also the form Xcode writes below 1e-4, `d[.ddd]e-dd` (proven for color components: `color-srgb-tiny`,
    /// `color-srgb-small-grid`).
    static func parse(_ s: String, exponent: Bool = false, negativeZero: Bool = false) -> Double? {
        let b = Array(s.utf8)
        func digits(_ i: inout Int) -> Int {
            let start = i
            while i < b.count, (0x30...0x39).contains(b[i]) { i += 1 }
            return i - start
        }
        var i = 0
        let negative = b.first == 0x2D
        if negative { i += 1 }
        let intStart = i
        let intDigits = digits(&i)
        guard intDigits > 0, intDigits == 1 || b[intStart] != 0x30 else { return nil }
        if i < b.count, b[i] == 0x2E {
            i += 1
            guard digits(&i) > 0 else { return nil }
        }
        if exponent, i < b.count, b[i] == 0x65 {
            // Mantissa d[.ddd] (one non-zero integer digit), then "e-" and two digits.
            guard intDigits == 1, b[intStart] != 0x30, !negative, i + 4 == b.count, b[i + 1] == 0x2D else { return nil }
            i += 2
            guard digits(&i) == 2 else { return nil }
        }
        guard i == b.count, let v = Double(s), v.isFinite, negativeZero || !(negative && v == 0) else { return nil }
        return v
    }
}
