import Foundation
import Testing
import CLZFSE
@testable import AssetKit

/// Verifies the vendored LZFSE encoder produces streams that round-trip
/// through the vendored decoder across a spread of representative inputs.
/// Runs on every platform; this is Linux's primary correctness gate for the
/// encoder path (macOS additionally has `LZFSECrossOracleTests` against
/// Apple's `Compression` framework, and `AssetutilParseTests` against
/// CoreUI itself).
@Suite("LZFSE encoder (vendored roundtrip)")
struct LZFSEEncodeTests {
    @Test("Empty input roundtrips")
    func empty() {
        roundtrip([])
    }

    @Test("Single byte roundtrips")
    func singleByte() {
        roundtrip([0x42])
    }

    @Test("All-zero buffer roundtrips (best-case compressor)")
    func allZeros() {
        roundtrip([UInt8](repeating: 0, count: 64 * 1024))
    }

    @Test("Highly repeating buffer roundtrips")
    func repeating() {
        let pattern: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        var bytes = [UInt8]()
        bytes.reserveCapacity(32 * 1024)
        for _ in 0..<(32 * 1024 / pattern.count) {
            bytes.append(contentsOf: pattern)
        }
        roundtrip(bytes)
    }

    @Test("Pseudo-random buffer roundtrips (worst case; tests envelope correctness)")
    func random() {
        var rng = SeededRNG(seed: 0xC0FFEE)
        var bytes = [UInt8](repeating: 0, count: 32 * 1024)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: rng.next()) }
        roundtrip(bytes)
    }

    @Test("BGRA bitmap chunk (the shape CSIWriter actually feeds the encoder)")
    func bgraBitmapChunk() {
        // 60x20 row-chunk of an 'AppIcon@2x' style buffer: most pixels opaque
        // mid-grey, a diagonal band of red. Hits the realistic mix of
        // run-length and small-window matches that LZFSE is tuned for.
        let width = 60, height = 20
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if x == y * (width / max(height, 1)) {
                    bytes[i + 0] = 0x00   // B
                    bytes[i + 1] = 0x00   // G
                    bytes[i + 2] = 0xFF   // R
                } else {
                    bytes[i + 0] = 0x80
                    bytes[i + 1] = 0x80
                    bytes[i + 2] = 0x80
                }
                bytes[i + 3] = 0xFF       // A
            }
        }
        roundtrip(bytes)
    }

    /// Encode `input` with our vendored encoder, decode with the vendored
    /// decoder, assert byte-equal.
    private func roundtrip(_ input: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) {
        let encoded = LZFSE.encode(input)

        // `max(_, 1)` because withUnsafeMutableBufferPointer on a zero-length
        // [UInt8] hands back a nil baseAddress; one slack byte avoids the
        // degenerate case without changing the assertion below.
        let decodeBound = max(input.count, 1)
        var decoded = [UInt8](repeating: 0, count: decodeBound)
        let decodedSize = encoded.withUnsafeBufferPointer { inBuf -> Int in
            decoded.withUnsafeMutableBufferPointer { outBuf in
                lzfse_decode_buffer(
                    outBuf.baseAddress!, decodeBound,
                    inBuf.baseAddress!, encoded.count,
                    nil
                )
            }
        }

        #expect(decodedSize == input.count, "decoded size mismatch", sourceLocation: sourceLocation)
        #expect(Array(decoded.prefix(decodedSize)) == input, "decoded bytes differ from input", sourceLocation: sourceLocation)
    }
}

/// Deterministic LCG so the random-buffer test is reproducible across runs
/// and platforms. Quality of randomness is not the point; reproducibility is.
private struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 0xDEADBEEF : seed }
    mutating func next() -> UInt64 {
        state &*= 6364136223846793005
        state &+= 1442695040888963407
        return state
    }
}
