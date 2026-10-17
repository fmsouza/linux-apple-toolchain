import Foundation

/// A Foundation scalar (from `JSONSerialization` or `PropertyListSerialization`) classified the same way on macOS and
/// Linux, where booleans and numbers decode differently: Darwin returns the shared `CFBoolean`s, swift-corelibs-
/// foundation its `__NSCFBoolean`s (both identical to `NSNumber(value: Bool)`) or, for plists, a Swift `Bool`.
public enum FoundationScalar: Equatable, Sendable {
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case real(Double)

    /// nil for anything that is not a boolean or a number (strings, collections, dates, data, null).
    public init?(_ v: Any) {
        if type(of: v) == Bool.self, let b = v as? Bool { self = .bool(b); return }
        guard let n = v as? NSNumber else { return nil }
        if n === NSNumber(value: true) { self = .bool(true); return }
        if n === NSNumber(value: false) { self = .bool(false); return }
        switch String(cString: n.objCType) {
        case "c", "B": self = .bool(n.boolValue)   // JSON and plist integers are 64-bit ("q"/"Q"), never "c"
        case "f", "d": self = .real(n.doubleValue)
        case "Q": self = .uint(n.uint64Value)
        default: self = .int(n.int64Value)
        }
    }
}
