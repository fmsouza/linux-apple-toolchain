import Foundation
import Testing
@testable import AssetKit

@Suite("SVG intrinsic-dimension parser")
struct SVGDimensionsTests {

    @Test("width + height attributes take precedence over viewBox")
    func widthHeightWin() throws {
        let svg = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200" width="50" height="40"/>
        """.utf8)
        let dims = try SVGSource.Dimensions.read(svg, asset: "X", filename: "x.svg")
        #expect(dims.width == 50)
        #expect(dims.height == 40)
    }

    @Test("viewBox-only SVG resolves to viewBox width/height")
    func viewBoxOnly() throws {
        // The shape that exposed the lowercased-lookup bug: viewBox in
        // canonical camelCase, no width / no height. Regression for
        // SVGDimensions.swift mis-keying the attribute dictionary.
        let svg = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">
          <rect x="4" y="4" width="192" height="192" fill="#6750A4"/>
        </svg>
        """.utf8)
        let dims = try SVGSource.Dimensions.read(svg, asset: "SampleVector", filename: "sample.svg")
        #expect(dims.width == 200)
        #expect(dims.height == 200)
    }

    @Test("px suffix is stripped from width / height")
    func pxSuffix() throws {
        let svg = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="64px" height="64px"/>
        """.utf8)
        let dims = try SVGSource.Dimensions.read(svg, asset: "X", filename: "x.svg")
        #expect(dims.width == 64)
        #expect(dims.height == 64)
    }

    @Test("comma-separated viewBox parses the same as space-separated")
    func commaViewBox() throws {
        let svg = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0,0,300,150"/>
        """.utf8)
        let dims = try SVGSource.Dimensions.read(svg, asset: "X", filename: "x.svg")
        #expect(dims.width == 300)
        #expect(dims.height == 150)
    }

    @Test("SVG with no usable size throws svgDimensionsMissing")
    func missingDimsThrows() {
        let svg = Data("""
        <svg xmlns="http://www.w3.org/2000/svg"><rect width="10" height="10"/></svg>
        """.utf8)
        #expect(throws: XCAssetCompilerError.self) {
            _ = try SVGSource.Dimensions.read(svg, asset: "X", filename: "x.svg")
        }
    }
}
