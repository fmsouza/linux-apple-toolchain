import Testing
import Foundation
@testable import XlessIB

@Test(arguments: [(0, [0x80]), (1, [0x81]), (127, [0xFF]), (128, [0x00, 0x81]), (300, [0x2C, 0x82])] as [(Int, [UInt8])])
func varintRoundTrip(value: Int, bytes: [UInt8]) throws {
    #expect(Varint.encode(value) == bytes)
    var i = 0
    #expect(try Varint.decode(Data(bytes), at: &i) == value)
    #expect(i == bytes.count)
}

@Test func varintTruncatedThrows() {
    var i = 0
    #expect(throws: (any Error).self) { try Varint.decode(Data([0x01, 0x02]), at: &i) }
}
