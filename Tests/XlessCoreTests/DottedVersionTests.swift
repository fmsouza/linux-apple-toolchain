import Testing
@testable import XlessCore

@Test func comparesAndPads() throws {
    #expect(DottedVersion("17") == DottedVersion("17.0.0"))
    #expect(try #require(DottedVersion("16.4")) < #require(DottedVersion("17.0")))
    #expect(DottedVersion("x.1") == nil)
    #expect(DottedVersion("1.2.3.4") == nil)
    #expect(DottedVersion("26.0.1")?.parts == [26, 0, 1])
}
