import Foundation
import XlessCore

/// A reference to an object being built; numbered only by `ArchiveBuilder.finish(root:)`.
public struct ObjectRef: Hashable, Sendable {
    let id: Int
}

/// Builds a `NIBArchive` the way ibtool lays one out (docs/research/nib-encoding.md, sections 3–5):
/// - objects are numbered depth-first, in order of first reference, from the root object;
/// - each object's values are contiguous, in object order;
/// - the key table is the enumeration order of CoreFoundation's string hash table, filled in that same walk;
/// - class names are listed in order of first use, then the fallback classes (`NSColor`, `NSFont`, …) not yet present,
///   and a class with a fallback carries the fallback's table index as its single extra.
///
/// Objects may be created in any order; only the reference graph and each object's key order matter.
/// Value objects that ibtool shares (strings, colors, …) go through `unique(_:_:)`.
public final class ArchiveBuilder {
    enum Value { case scalar(NIBValueData), object(ObjectRef) }
    struct Object { var className: String; var values: [(key: String, value: Value)] = [] }

    private var objects: [Object] = []
    private var fallbacks: [String: String] = [:]
    /// Keyed by the identity's UTF-8 bytes: Swift `String` equality is Unicode canonical equivalence, but ibtool keeps
    /// NFC and NFD spellings of the same text apart (`label-text-forms`: "Café" twice, 5 and 6 bytes).
    private var uniqued: [Data: ObjectRef] = [:]

    public init() {}

    /// Creates an object of `className`. `fallback` names the class's fallback class (`UIColor` → `NSColor`).
    public func object(_ className: String, fallback: String? = nil) -> ObjectRef {
        if let fallback { fallbacks[className] = fallback }
        objects.append(Object(className: className))
        return ObjectRef(id: objects.count - 1)
    }

    /// Appends a scalar value. Object references go through `set(_:_:_:)` with an `ObjectRef`.
    public func set(_ ref: ObjectRef, _ key: String, _ value: NIBValueData) {
        if case .object = value { preconditionFailure("use set(_:_:_ child: ObjectRef) for object references") }
        objects[ref.id].values.append((key, .scalar(value)))
    }

    /// Appends a reference to another object.
    public func set(_ ref: ObjectRef, _ key: String, _ child: ObjectRef) {
        objects[ref.id].values.append((key, .object(child)))
    }

    /// Returns the object previously made for `identity`, or makes it with `make` and remembers it.
    /// `identity` must capture everything that ibtool's equality compares (class and encoded content).
    public func unique(_ identity: String, _ make: () throws -> ObjectRef) rethrows -> ObjectRef {
        let key = Data(identity.utf8)
        if let r = uniqued[key] { return r }
        let r = try make()
        uniqued[key] = r
        return r
    }

    /// Lays the graph reachable from `root` out as a NIB archive.
    public func finish(root: ObjectRef) throws -> NIBArchive {
        // Depth-first walk: number objects on first reference; record keys as their values are encoded.
        var number: [Int: Int] = [root.id: 0]
        var order = [root.id]
        var keyOrder: [String] = []
        var keySeen = Set<String>()
        var stack: [(id: Int, next: Int)] = [(root.id, 0)]
        while let (id, next) = stack.popLast() {
            let values = objects[id].values
            guard next < values.count else { continue }
            stack.append((id, next + 1))
            let (key, value) = values[next]
            if keySeen.insert(key).inserted { keyOrder.append(key) }
            if case .object(let child) = value, number[child.id] == nil {
                number[child.id] = order.count
                order.append(child.id)
                stack.append((child.id, 0))
            }
        }

        var a = NIBArchive()
        let keys = try Self.keyTableOrder(keyOrder)
        let keyIndex = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
        a.keys = keys.map { Data($0.utf8) }

        var classNames: [String] = []
        var classIndex: [String: Int] = [:]
        func addClass(_ n: String) {
            if classIndex[n] == nil { classIndex[n] = classNames.count; classNames.append(n) }
        }
        for id in order { addClass(objects[id].className) }
        let used = Set(classNames)
        for fb in Self.fallbackOrder where used.contains(where: { fallbacks[$0] == fb }) { addClass(fb) }
        a.classNames = classNames.map { n in
            NIBClassName(name: Data(n.utf8), extras: fallbacks[n].map { [Int32(classIndex[$0]!)] } ?? [])
        }

        for id in order {
            let o = objects[id]
            a.objects.append(NIBObject(classNameIndex: classIndex[o.className]!, valuesStart: a.values.count, valueCount: o.values.count))
            for (key, value) in o.values {
                let data: NIBValueData
                switch value {
                case .scalar(let d): data = d
                case .object(let r): data = .object(UInt32(number[r.id]!))
                }
                a.values.append(NIBValue(keyIndex: keyIndex[key]!, data: data))
            }
        }
        return a
    }

    /// The order in which fallback classes are appended to the class table (section 5).
    static let fallbackOrder = ["NSColor", "NSFont", "UIView", "NSLayoutConstraint"]

    // MARK: Key table (section 4)

    /// Table sizes and the key count each holds before growing. The capacity of 191 is unknown (Open question 5); it
    /// holds at least 107 keys.
    static let tableSizes: [(size: Int, capacity: Int?)] = [(3, 2), (7, 6), (13, 12), (23, 20), (41, 33), (71, 53), (127, 86), (191, nil)]
    /// The largest key count proven in the corpus (`keys-count-92` … `keys-count-107`, `keys-count-legacy`): 107 is
    /// every key the rules can write next to the safe area, so no supported storyboard should exceed it; beyond it the
    /// table's growth is unverified.
    static let maxVerifiedKeyCount = 107

    /// The enumeration order of a CoreFoundation string hash table after inserting `keys` in order.
    static func keyTableOrder(_ keys: [String]) throws -> [String] {
        guard keys.count <= maxVerifiedKeyCount else {
            throw XlessError(.ib, "unsupported: \(keys.count) distinct NIB keys; key tables above \(maxVerifiedKeyCount) keys are unverified (see docs/research/nib-encoding.md#open-questions)",
                             fix: "simplify the launch screen (fewer distinct view kinds and properties)")
        }
        var level = 0
        var table = [String?](repeating: nil, count: tableSizes[0].size)
        func insert(_ k: String, into t: inout [String?]) {
            var i = Int(cfStringHash(k) % UInt64(t.count))
            while t[i] != nil { i = (i + 1) % t.count }
            t[i] = k
        }
        for (n, k) in keys.enumerated() {
            insert(k, into: &table)
            if let cap = tableSizes[level].capacity, n + 1 > cap {
                let old = table.compactMap { $0 }
                level += 1
                table = [String?](repeating: nil, count: tableSizes[level].size)
                for o in old { insert(o, into: &table) }
            }
        }
        return table.compactMap { $0 }
    }

    /// CoreFoundation's published 8-bit string hash (`__CFStrHashEightBit`), for keys up to 96 bytes.
    static func cfStringHash(_ s: String) -> UInt64 {
        let b = Array(s.utf8)
        precondition(b.count <= 96, "NIB key longer than 96 bytes: \(s)")
        let n = b.count
        var h = UInt64(n)
        var i = 0
        while i + 4 <= n {
            h = h &* 67503105 &+ UInt64(b[i]) &* 16974593 &+ UInt64(b[i + 1]) &* 66049 &+ UInt64(b[i + 2]) &* 257 &+ UInt64(b[i + 3])
            i += 4
        }
        while i < n { h = h &* 257 &+ UInt64(b[i]); i += 1 }
        return h &+ (h << UInt64(n & 31))
    }

    // MARK: Value helpers (section 6, "Common containers")

    /// An integer in the smallest width ibtool was seen to use: int8 for 0…127, int16 for 128…32767,
    /// int64 for negative values and values ≥ 2^31. int32 was never observed (Open question 9).
    static func int(_ v: Int) throws -> NIBValueData {
        switch v {
        case 0...127: return .int8(Int8(v))
        case 128...32767: return .int16(Int16(v))
        case ..<0, (Int(Int32.max) + 1)...: return .int64(Int64(v))
        default:
            throw XlessError(.ib, "unsupported: integer \(v) needs the int32 width, which ibtool was never seen to use (see docs/research/nib-encoding.md#open-questions)",
                             fix: "use a smaller value")
        }
    }

    /// `07` followed by little-endian doubles: a point (2) or a rect (4).
    static func doubles(_ xs: [Double]) -> NIBValueData {
        var d = Data([0x07])
        for x in xs { withUnsafeBytes(of: x.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        return .data(d)
    }

    /// A shared `NSString` (`NS.bytes` = UTF-8 bytes, no terminator).
    public func string(_ s: String) -> ObjectRef {
        unique("NSString|" + s) {
            let r = object("NSString")
            set(r, "NS.bytes", .data(Data(s.utf8)))
            return r
        }
    }

    /// A shared `NSNumber`: `NS.dblval` = double, or `NS.intval` = integer when `integer`. Numbers are shared by value,
    /// across both forms: the first one created wins (`label-font-grid`: the italic trait `intval 1` is reused as the
    /// size 1.0 of later fonts, as `NSNumber` equality compares values).
    public func number(_ v: Double, integer: Bool = false) throws -> ObjectRef {
        try unique("NSNumber|\(v == 0 ? 0 : v)") {
            let r = object("NSNumber")
            if integer {
                guard let i = Int(exactly: v) else { preconditionFailure("integer NSNumber \(v)") }
                set(r, "NS.intval", try Self.int(i))
            } else {
                set(r, "NS.dblval", .double(v))
            }
            return r
        }
    }

    /// A shared `NSDictionary`/`NSMutableDictionary`: `NSInlinedValue` = YES, then key, value, key, value … each as
    /// `UINibEncoderEmptyKey`, in the given order. Equal dictionaries are one object (`label-font-grid`: the italic
    /// fonts share their traits dictionary). `identity` must describe the entries.
    public func dictionary(_ entries: [(key: ObjectRef, value: ObjectRef)], identity: String, mutable: Bool = false) -> ObjectRef {
        unique("NSDictionary|" + identity) {
            let r = object(mutable ? "NSMutableDictionary" : "NSDictionary")
            set(r, "NSInlinedValue", .bool(true))
            for (k, v) in entries {
                set(r, "UINibEncoderEmptyKey", k)
                set(r, "UINibEncoderEmptyKey", v)
            }
            return r
        }
    }

    /// An `NSArray`/`NSMutableArray` of `items`. Arrays are never shared, except the empty `NSArray`.
    public func array(_ items: [ObjectRef], mutable: Bool = false) -> ObjectRef {
        if items.isEmpty && !mutable { return unique("NSArray|empty") { makeArray([], className: "NSArray") } }
        return makeArray(items, className: mutable ? "NSMutableArray" : "NSArray")
    }

    private func makeArray(_ items: [ObjectRef], className: String) -> ObjectRef {
        let r = object(className)
        set(r, "NSInlinedValue", .bool(true))
        for i in items { set(r, "UINibEncoderEmptyKey", i) }
        return r
    }
}
