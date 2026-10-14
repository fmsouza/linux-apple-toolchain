#if canImport(Compression)
import Compression
import Foundation
import Testing
@testable import AssetKit

/// Second-source oracle: encode with the vendored LZFSE encoder, decode with
/// Apple's `Compression` framework. Catches encoder bugs that a vendored
/// encode-then-vendored-decode roundtrip would silently agree on.
///
/// macOS-only because `Compression` is Darwin-only; on Linux the durable
/// gate is `LZFSEEncodeTests` plus the in-CI vendored roundtrip.
@Suite("LZFSE encoder (cross-oracle against Apple Compression)")
struct LZFSECrossOracleTests {
    @Test("Empty input decodes to empty via Apple Compression")
    func empty() {
        crossDecode([])
    }

    @Test("All-zero buffer decodes to all-zero via Apple Compression")
    func allZeros() {
        crossDecode([UInt8](repeating: 0, count: 64 * 1024))
    }

    @Test("Pseudo-random buffer decodes byte-identical via Apple Compression")
    func random() {
        var state: UInt64 = 0xC0FFEE
        var bytes = [UInt8](repeating: 0, count: 32 * 1024)
        for i in bytes.indices {
            state &*= 6364136223846793005
            state &+= 1442695040888963407
            bytes[i] = UInt8(truncatingIfNeeded: state >> 56)
        }
        crossDecode(bytes)
    }

    @Test("BGRA bitmap chunk decodes byte-identical via Apple Compression")
    func bgraBitmapChunk() {
        let width = 60, height = 20
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i + 0] = UInt8((x &* 7) & 0xFF)
                bytes[i + 1] = UInt8((y &* 13) & 0xFF)
                bytes[i + 2] = UInt8(((x ^ y) &* 31) & 0xFF)
                bytes[i + 3] = 0xFF
            }
        }
        crossDecode(bytes)
    }

    private func crossDecode(_ input: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) {
        let encoded = LZFSE.encode(input)

        let decodeBound = max(input.count, 1)
        var decoded = [UInt8](repeating: 0, count: decodeBound)
        let decodedSize = encoded.withUnsafeBufferPointer { inBuf -> Int in
            decoded.withUnsafeMutableBufferPointer { outBuf in
                compression_decode_buffer(
                    outBuf.baseAddress!, decodeBound,
                    inBuf.baseAddress!, encoded.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }

        #expect(decodedSize == input.count, "Apple Compression decoded size mismatch", sourceLocation: sourceLocation)
        #expect(Array(decoded.prefix(decodedSize)) == input, "Apple Compression decoded bytes differ from input", sourceLocation: sourceLocation)
    }
}
#endif
