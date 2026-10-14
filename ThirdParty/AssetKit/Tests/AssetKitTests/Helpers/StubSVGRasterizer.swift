import Foundation
import PNG
@testable import AssetKit

/// Deterministic test-only `SVGRasterizer`. Produces a real PNG of exactly
/// the requested dimensions (so the rendered BitmapBody has matching
/// dimensions and the byte pipeline behaves end-to-end) and records every
/// call so tests can assert the compiler made the right requests.
///
/// Lives in `Tests/.../Helpers/` so multiple test files can inject the
/// same shared fake without depending on `rsvg-convert` being installed.
final class StubSVGRasterizer: SVGRasterizer, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(width: UInt32, height: UInt32)] = []

    var callsRecorded: [(width: UInt32, height: UInt32)] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func rasterize(svgData: Data, pixelWidth: UInt32, pixelHeight: UInt32) throws -> Data {
        lock.lock()
        _calls.append((pixelWidth, pixelHeight))
        lock.unlock()
        let pixelCount = Int(pixelWidth) * Int(pixelHeight)
        // Solid magenta — distinctive so a misrouted pixel buffer is
        // visually obvious in any downstream diagnostic.
        let rgba = [PNG.RGBA<UInt8>](repeating: PNG.RGBA<UInt8>(255, 0, 255, 255), count: pixelCount)
        let layout = PNG.Layout(format: .rgba8(palette: [], fill: nil))
        let image = PNG.Image(
            packing: rgba,
            size: (x: Int(pixelWidth), y: Int(pixelHeight)),
            layout: layout
        )
        var stream = MemoryBytestreamDestination()
        try image.compress(stream: &stream)
        return Data(stream.bytes)
    }
}

struct MemoryBytestreamDestination: PNG.BytestreamDestination {
    var bytes: [UInt8] = []
    mutating func write(_ data: [UInt8]) -> Void? {
        bytes.append(contentsOf: data)
        return ()
    }
}

enum RsvgConvertProbe {
    static var isAvailable: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "rsvg-convert"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
