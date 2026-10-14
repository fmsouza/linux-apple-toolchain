import Foundation
import Testing
@testable import AssetKit

/// Byte-equality tests for preserved-source renditions (SVG, JPG) against
/// the dumped reference Assets.car. The reference bytes live at
/// `Fixtures/Reference/Svg.csi.bin` (449 B) and `Fixtures/Reference/Jpg.csi.bin`
/// (6085 B); each file is exactly the CSI header + TVL + DWAR envelope for
/// the matching rendition lifted from actool's Xcode 26 output.
///
/// These tests are the durable verification for CoreUI 970 preserved-source
/// compatibility. They run on every platform (Linux included), unlike
/// `AssetutilParseTests` which can only run on macOS.
@Suite("Preserved-source rendition byte parity")
struct PreservedSourceTests {

    @Test("SVG preserved-source rendition matches the reference byte-for-byte")
    func svgMatchesReference() throws {
        let body = PreservedSourceBody(
            format: .svg,
            sourceData: try loadFixture("Svg.imageset/Svg.svg"),
            renditionName: "Svg.svg"
        )
        let encoded = CSIWriter.preservedSource(body: body, scaleFactor: 0)
        let reference = try loadReference("Svg.csi.bin")
        try expectEqual(encoded, reference, label: "SVG")
    }

    @Test("JPG preserved-source rendition matches the reference byte-for-byte")
    func jpgMatchesReference() throws {
        let sourceData = try loadFixture("Jpg.imageset/Jpg@2x.jpg")
        let dims = try JPEGSource.Dimensions.read(sourceData)
        #expect(dims.width == 120, "fixture JPEG width should be 120")
        #expect(dims.height == 120, "fixture JPEG height should be 120")
        let body = PreservedSourceBody(
            format: .jpeg(width: dims.width, height: dims.height),
            sourceData: sourceData,
            renditionName: "Jpg@2x.jpg"
        )
        let encoded = CSIWriter.preservedSource(body: body, scaleFactor: 200)
        let reference = try loadReference("Jpg.csi.bin")
        try expectEqual(encoded, reference, label: "JPG")
    }

    @Test("DWAR envelope framing is 12 bytes plus payload")
    func dwarEnvelopeFraming() {
        let payload: [UInt8] = [0xAA, 0xBB, 0xCC]
        let envelope = DWAREnvelope.encode(flags: 0, payload: payload)
        let bytes = [UInt8](envelope)
        #expect(bytes.count == 12 + payload.count)
        #expect(Array(bytes.prefix(4)) == Array("DWAR".utf8))
        // flags u32 LE = 0
        #expect(Array(bytes[4..<8]) == [0, 0, 0, 0])
        // innerLen u32 LE = 3
        #expect(Array(bytes[8..<12]) == [3, 0, 0, 0])
        #expect(Array(bytes[12..<15]) == payload)
    }

    @Test("End-to-end compile includes the SVG and JPG renditions")
    func endToEnd() async throws {
        let bundle = Bundle.module
        guard let fixtureURL = bundle.url(
            forResource: "Test",
            withExtension: "xcassets",
            subdirectory: "Fixtures"
        ) else {
            Issue.record("Fixtures/Test.xcassets missing from test bundle")
            return
        }
        // Inject the stub rasteriser so this test passes on hosts without
        // rsvg-convert installed. The DWAR/JPG checks below don't depend on
        // pixel content, only on the preserved-source envelope appearing in
        // the compiled CAR.
        let compiler = XCAssetCompiler(deploymentTarget: "16.0", svgRasterizer: StubSVGRasterizer())
        let result = try await compiler.compile(catalog: fixtureURL)
        let bytes = [UInt8](result.carData)
        // The encoded DWAR envelopes from our two fixtures must appear
        // verbatim somewhere in the compiled CAR.
        let svg = try loadFixture("Svg.imageset/Svg.svg")
        let jpg = try loadFixture("Jpg.imageset/Jpg@2x.jpg")
        // SVG body is LZFSE-compressed; check for the DWAR magic + flags=1
        // sequence preceding an LZFSE bvxn frame.
        let svgEnvelopeHead: [UInt8] = Array("DWAR".utf8) + [0x01, 0, 0, 0]
        #expect(bytes.containsSequence(svgEnvelopeHead),
                "compiled CAR is missing a DWAR(flags=1) envelope for the SVG rendition")
        // JPG body is raw; the entire JPEG should sit verbatim inside the CAR.
        #expect(bytes.containsSequence([UInt8](jpg)),
                "compiled CAR is missing the raw JPEG bytes")
        // Sanity: source SVG bytes are NOT present verbatim (they should be
        // LZFSE-compressed, not raw).
        #expect(!bytes.containsSequence([UInt8](svg)),
                "SVG source should be LZFSE-compressed, not raw, inside the CAR")
    }

    // MARK: - Helpers

    private func loadFixture(_ relative: String) throws -> Data {
        let url = try fixtureBaseURL().appendingPathComponent(relative)
        return try Data(contentsOf: url)
    }

    private func loadReference(_ name: String) throws -> Data {
        let url = try fixtureBaseURL()
            .deletingLastPathComponent()
            .appendingPathComponent("Reference")
            .appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    private func fixtureBaseURL() throws -> URL {
        guard let url = Bundle.module.url(
            forResource: "Test",
            withExtension: "xcassets",
            subdirectory: "Fixtures"
        ) else {
            throw FixtureError.missingTestXCAssets
        }
        return url
    }

    private enum FixtureError: Error { case missingTestXCAssets }

    private func expectEqual(_ actual: Data, _ expected: Data, label: String) throws {
        if actual == expected { return }
        let diff = firstDifference(actual, expected)
        Issue.record("""
        \(label) rendition bytes diverge from reference.
        actual:   \(actual.count) bytes
        expected: \(expected.count) bytes
        first diff at offset \(diff): actual=\(hexBytes(actual, around: diff)) expected=\(hexBytes(expected, around: diff))
        """)
    }

    private func firstDifference(_ a: Data, _ b: Data) -> Int {
        let n = min(a.count, b.count)
        for i in 0..<n {
            if a[a.index(a.startIndex, offsetBy: i)] != b[b.index(b.startIndex, offsetBy: i)] {
                return i
            }
        }
        return n
    }

    private func hexBytes(_ data: Data, around offset: Int) -> String {
        let lo = max(offset - 4, 0)
        let hi = min(offset + 8, data.count)
        let slice = data[data.index(data.startIndex, offsetBy: lo)..<data.index(data.startIndex, offsetBy: hi)]
        return slice.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

private extension Array where Element == UInt8 {
    func containsSequence(_ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        let last = count - needle.count
        for i in 0...last where self[i] == needle[0] {
            var match = true
            for j in 1..<needle.count where self[i + j] != needle[j] {
                match = false
                break
            }
            if match { return true }
        }
        return false
    }
}
