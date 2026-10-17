import Testing
import Foundation
@testable import XlessXcode
@testable import XlessCore

/// `JSON(foundation:)` keeps JSON's types on macOS and Linux: booleans are not integers, integers are not booleans,
/// and `null` or a fraction (which a PIF never holds) is refused instead of being guessed.
@Test func foundationJSONKeepsBooleansAndRefusesNullAndFractions() throws {
    let parsed = try JSONSerialization.jsonObject(with: Data(#"[true, false, 1, 0, 7, "s", {"k": [true]}]"#.utf8))
    #expect(try JSON(foundation: parsed) == .array([.bool(true), .bool(false), .int(1), .int(0), .int(7), .string("s"), .object(["k": .array([.bool(true)])])]))
    for bad in [#"[null]"#, #"{"a": null}"#, #"[2.5]"#] {
        let v = try JSONSerialization.jsonObject(with: Data(bad.utf8))
        #expect(throws: XlessError.self) { try JSON(foundation: v) }
    }
    #expect(try JSON(foundation: JSONSerialization.jsonObject(with: Data("[2.0]".utf8))) == .array([.int(2)]))
}
