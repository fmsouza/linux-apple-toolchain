import Foundation
import Testing
import PNG
@testable import AssetKit

/// Verifies that a `.svg` source produces the expected rendition fan-out:
/// one preserved-source vector rendition plus three rasterised bitmap
/// renditions at 1x / 2x / 3x. Uses an injectable stub rasteriser so the
/// tests run on every host regardless of whether `rsvg-convert` is
/// installed; a separate gated test exercises the real rasteriser.
@Suite("SVG raster fanout")
struct SVGRasterFanoutTests {

    @Test("One SVG asset compiles to one vector + three bitmap renditions")
    func renditionFanout() async throws {
        let renditions = try await compileFixture(svgRasterizer: StubSVGRasterizer())
        let svgRenditions = renditions.filter { $0.name == "Svg" }
        #expect(svgRenditions.count == 4, "expected 1 vector + 3 bitmap renditions, got \(svgRenditions.count)")

        let vector = svgRenditions.filter {
            if case .preservedSource = $0.body { return true } else { return false }
        }
        #expect(vector.count == 1)
        #expect(vector.first?.scale == .x1, "vector source rendition packs into the scale=1 slot per ADR 0002")

        let bitmaps = svgRenditions.filter {
            if case .bitmap = $0.body { return true } else { return false }
        }
        #expect(bitmaps.count == 3)
        let scales = Set(bitmaps.compactMap { $0.scale })
        #expect(scales == Set<Scale>([.x1, .x2, .x3]), "bitmap fanout should cover 1x/2x/3x")
    }

    @Test("Rasterised bitmap dimensions = intrinsic × scale factor")
    func rasterisedDimensions() async throws {
        // The fixture SVG declares width=100 height=100.
        let stub = StubSVGRasterizer()
        let renditions = try await compileFixture(svgRasterizer: stub)
        let bitmaps: [Rendition] = renditions.filter { rendition in
            guard rendition.name == "Svg" else { return false }
            if case .bitmap = rendition.body { return true } else { return false }
        }
        for rendition in bitmaps {
            guard case .bitmap(let body) = rendition.body else { continue }
            let expected = UInt32(rendition.scale?.factor ?? 0) * 100
            #expect(body.width == expected, "rendition at \(String(describing: rendition.scale)) width")
            #expect(body.height == expected, "rendition at \(String(describing: rendition.scale)) height")
        }
        // The stub records every rasterise() call. Verify the compiler asked
        // for the three exact pixel sizes — not more, not fewer.
        let calls = stub.callsRecorded.sorted { $0.width < $1.width }
        let actualPairs = calls.map { [$0.width, $0.height] }
        #expect(actualPairs == [[100, 100], [200, 200], [300, 300]], "rasteriser call sizes")
    }

    @Test(
        "Real rsvg-convert default produces valid PNG bytes",
        .enabled(if: RsvgConvertProbe.isAvailable)
    )
    func realRsvgConvertProducesPNG() throws {
        let svg = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10" width="10" height="10">
          <rect width="10" height="10" fill="#ff0000"/>
        </svg>
        """.utf8)
        let png = try RsvgConvertRasterizer().rasterize(svgData: svg, pixelWidth: 20, pixelHeight: 20)
        // PNG signature.
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        #expect(Array(png.prefix(8)) == signature)
        // Decode back through swift-png to confirm shape.
        let (w, h, _) = try PNGSource.decodeBGRA(png)
        #expect(w == 20)
        #expect(h == 20)
    }

    // MARK: - Helpers

    /// Returns the rendition list the compiler would produce for the
    /// fixture catalog with the given rasteriser. Drives only the loader +
    /// ImageRenderer paths — does not run the full BOM/CAR writer — so
    /// every rasteriser call counted is from one logical compile pass.
    private func compileFixture(svgRasterizer: any SVGRasterizer) async throws -> [Rendition] {
        guard let fixtureURL = Bundle.module.url(
            forResource: "Test",
            withExtension: "xcassets",
            subdirectory: "Fixtures"
        ) else {
            throw FixtureError.missing
        }
        let loader = CatalogLoader()
        let loaded = try await loader.load(catalog: fixtureURL)
        var renditions: [Rendition] = []
        for imageSet in loaded.imageSets {
            renditions.append(contentsOf: try ImageRenderer.renditions(
                for: imageSet,
                svgRasterizer: svgRasterizer
            ))
        }
        return renditions
    }

    private enum FixtureError: Error { case missing }
}

