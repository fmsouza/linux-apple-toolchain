import Foundation
import Testing
@testable import AssetKit

@Suite("ColorRenderer")
struct ColorRendererTests {
    @Test("Parses sRGB float components")
    func parsesFloats() throws {
        let json = """
        {
          "info": { "version": 1, "author": "xcode" },
          "colors": [
            {
              "idiom": "universal",
              "color": {
                "color-space": "srgb",
                "components": {
                  "red": "0.5", "green": "0.25", "blue": "0.75", "alpha": "1.0"
                }
              }
            }
          ]
        }
        """
        let contents = try JSONDecoder().decode(ColorSetContents.self, from: Data(json.utf8))
        let set = LoadedColorSet(
            name: "Accent",
            directory: URL(fileURLWithPath: "/"),
            contents: contents
        )
        let renditions = try ColorRenderer.renditions(for: set)
        #expect(renditions.count == 1)
        guard case .color(let body) = renditions[0].body else {
            Issue.record("expected color body")
            return
        }
        #expect(abs(body.red - 0.5) < 1e-9)
        #expect(abs(body.green - 0.25) < 1e-9)
        #expect(abs(body.blue - 0.75) < 1e-9)
        #expect(abs(body.alpha - 1) < 1e-9)
        #expect(body.colorSpaceID == 1)
    }

    @Test("Honours display-P3 gamut")
    func parsesP3() throws {
        let json = """
        {
          "info": { "version": 1, "author": "xcode" },
          "colors": [
            {
              "idiom": "universal",
              "display-gamut": "display-P3",
              "color": {
                "color-space": "display-p3",
                "components": {
                  "red": "1.0", "green": "0.0", "blue": "0.0", "alpha": "1.0"
                }
              }
            }
          ]
        }
        """
        let contents = try JSONDecoder().decode(ColorSetContents.self, from: Data(json.utf8))
        let set = LoadedColorSet(name: "P3Red", directory: URL(fileURLWithPath: "/"), contents: contents)
        let renditions = try ColorRenderer.renditions(for: set)
        #expect(renditions.count == 1)
        #expect(renditions[0].gamut == .displayP3)
        guard case .color(let body) = renditions[0].body else {
            Issue.record("expected color body")
            return
        }
        // A named color's body carries actool's color space ID: display-p3 is 3 (2 is gray-gamma-22).
        #expect(body.colorSpaceID == 3)
    }

    @Test("Parses 0x-prefixed hex components")
    func parsesHex() throws {
        let json = """
        {
          "info": { "version": 1, "author": "xcode" },
          "colors": [
            {
              "idiom": "universal",
              "color": {
                "color-space": "srgb",
                "components": {
                  "red": "0xFF", "green": "0x00", "blue": "0x80", "alpha": "1.0"
                }
              }
            }
          ]
        }
        """
        let contents = try JSONDecoder().decode(ColorSetContents.self, from: Data(json.utf8))
        let set = LoadedColorSet(name: "Hex", directory: URL(fileURLWithPath: "/"), contents: contents)
        let renditions = try ColorRenderer.renditions(for: set)
        guard case .color(let body) = renditions[0].body else {
            Issue.record("expected color body")
            return
        }
        #expect(abs(body.red - 1) < 1e-9)
        #expect(abs(body.green - 0) < 1e-9)
        #expect(abs(body.blue - 128 / 255) < 1e-9)
    }

    /// actool 27.0 (measured): "1" is 1/255 and "255" is 1.0, but "1.5" is 1.5 and "0.2" goes through Float.
    @Test("Integer components are 8-bit values; decimal ones are taken as is, through Float")
    func integerVersusDecimal() throws {
        let json = """
        {
          "info": { "version": 1, "author": "xcode" },
          "colors": [
            { "idiom": "universal", "color": { "color-space": "extended-srgb",
              "components": { "red": "255", "green": "1", "blue": "1.5", "alpha": "0.2" } } }
          ]
        }
        """
        let contents = try JSONDecoder().decode(ColorSetContents.self, from: Data(json.utf8))
        let set = LoadedColorSet(name: "Mixed", directory: URL(fileURLWithPath: "/"), contents: contents)
        guard case .color(let body) = try ColorRenderer.renditions(for: set)[0].body else {
            Issue.record("expected color body")
            return
        }
        #expect(body.red == 1)
        #expect(body.green == 1.0 / 255)
        #expect(body.blue == 1.5)
        #expect(body.alpha == Double(Float(0.2)))
        #expect(body.colorSpaceID == 4)
    }
}
