import Testing
import Foundation
@testable import XlessMachO

/// PNG signature + IHDR chunk only (enough for header parsing).
func fakePNG(width: UInt32, height: UInt32, colorType: UInt8) -> Data {
    var d = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    func be(_ v: UInt32) { var x = v.bigEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    be(13); d.append(contentsOf: Array("IHDR".utf8)); be(width); be(height)
    d.append(contentsOf: [8, colorType, 0, 0, 0]); be(0)
    return d
}

@Test func parsesPNGHeader() throws {
    let h = try PNGHeader.parse(fakePNG(width: 1024, height: 1024, colorType: 2))
    #expect(h.width == 1024 && h.height == 1024 && !h.hasAlpha)
    #expect(try PNGHeader.parse(fakePNG(width: 16, height: 16, colorType: 6)).hasAlpha)
}

@Test func buildsICNS() throws {
    let a = fakePNG(width: 1024, height: 1024, colorType: 2), b = fakePNG(width: 512, height: 512, colorType: 2)
    let icns = try ICNS.make(pngs: [a, b])
    #expect(icns.prefix(4) == Data("icns".utf8))
    #expect(UInt32(bigEndian: icns.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }) == UInt32(icns.count))
    #expect(icns.subdata(in: 8..<12) == Data("ic10".utf8))
    #expect(icns.range(of: Data("ic09".utf8)) != nil)
}

@Test func icnsRejectsUnsupportedSize() {
    #expect(throws: (any Error).self) { try ICNS.make(pngs: [fakePNG(width: 100, height: 100, colorType: 2)]) }
}
