import Foundation

/// MLEC wrapper for bitmap pixels, framed in one or three KCBC chunks.
///
/// Layout verified against actool's reference Assets.car:
///
///   MLEC magic        4 bytes
///   flags             u32  bit 1 (0x2) = every pixel is opaque; bit 0 (0x1) is
///                          set in every chunked body actool writes
///   compression       u32  (4 = LZFSE in KCBC chunks)
///   chunkCount        u32  (1 or 3)
///   then chunkCount * KCBC chunks
///
/// The flags word is what `assetutil --info` reports as `Opaque`, and CoreUI
/// draws a rendition flagged opaque without its alpha (a transparent PNG
/// shows on a black square). Measured with actool 27.0 on neutral PNGs:
/// chunked LZFSE app icons carry 3 when every alpha is 255 and 1 otherwise;
/// actool's deepmap2 bodies (compression 11, not written here) carry 2 and 0
/// by the same rule.
///
/// Each KCBC chunk:
///
///   KCBC magic        4 bytes
///   reserved          8 zero bytes
///   chunkHeight       u32  (rows covered by this chunk)
///   payloadSize       u32  (bytes of compressed payload following)
///   payload[]         LZFSE bvx2 stream
///
/// Chunking policy mirrors actool: when height divides evenly by 3, emit 3
/// chunks of equal row height (120 -> 3x40, 180 -> 3x60); otherwise emit a
/// single chunk covering the whole image. The 3-chunk split is mimicry
/// rather than a correctness requirement: CoreUI accepts both layouts.
enum MLECBody {
    static let flagChunked: UInt32 = 0x1
    static let flagOpaque: UInt32 = 0x2
    static let compressionLZFSE: UInt32 = 4

    static func encode(width: UInt32, height: UInt32, pixelsBGRA: [UInt8], opaque: Bool) -> Data {
        let bytesPerRow = Int(width) * 4
        let canChunkInThree = height % 3 == 0
        let chunkCount: UInt32 = canChunkInThree ? 3 : 1
        let rowsPerChunk = height / chunkCount

        var chunks: [(rows: UInt32, payload: [UInt8])] = []
        for i in 0..<Int(chunkCount) {
            let start = i * Int(rowsPerChunk) * bytesPerRow
            let end = start + Int(rowsPerChunk) * bytesPerRow
            let slice = Array(pixelsBGRA[start..<end])
            chunks.append((rows: rowsPerChunk, payload: LZFSE.encode(slice)))
        }

        var w = ByteWriter()
        w.writeFourCC("MLEC")
        w.writeLE(flagChunked | (opaque ? flagOpaque : 0))
        w.writeLE(compressionLZFSE)
        w.writeLE(chunkCount)

        for chunk in chunks {
            w.writeFourCC("KCBC")
            w.writeZeros(8)                     // reserved
            w.writeLE(chunk.rows)               // chunkHeight (rows)
            w.writeLE(UInt32(chunk.payload.count))
            w.write(chunk.payload)
        }
        return w.data
    }
}
