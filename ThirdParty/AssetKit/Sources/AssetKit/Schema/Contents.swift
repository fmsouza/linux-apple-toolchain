import Foundation

enum Idiom: String, Codable, Sendable, Hashable {
    case universal
    case iphone
    case ipad
    case mac
    case tv
    case watch
    case car
    case marketing = "ios-marketing"

    var rawValueByte: UInt16 {
        switch self {
        case .universal: return 0
        case .iphone: return 1
        case .ipad: return 2
        case .tv: return 3
        case .car: return 4
        case .watch: return 5
        case .marketing: return 6
        case .mac: return 7
        }
    }
}

enum Scale: String, Codable, Sendable, Hashable {
    case x1 = "1x"
    case x2 = "2x"
    case x3 = "3x"

    var factor: Int {
        switch self {
        case .x1: return 1
        case .x2: return 2
        case .x3: return 3
        }
    }

    var rawValueByte: UInt16 { UInt16(factor) }
}

enum Gamut: String, Codable, Sendable, Hashable {
    case sRGB
    case displayP3 = "display-P3"

    /// CoreUI's per-rendition colorSpaceID (stored in the CSI header). Values
    /// derived from actool's reference Assets.car (Xcode 26 / CoreUI 970):
    /// sRGB renditions carry colorSpaceID=1, display-P3 carries 2.
    var colorSpaceID: UInt8 {
        switch self {
        case .sRGB: return 1
        case .displayP3: return 2
        }
    }

    /// Token used in the rendition key's appearance-adjacent slot. Distinct
    /// from `colorSpaceID` because CoreUI's KEYFORMAT no longer encodes
    /// display-gamut as a top-level key (the slot is gone in v1), but this
    /// value is retained for any internal callers that still distinguish.
    var rawValueByte: UInt16 {
        switch self {
        case .sRGB: return 0
        case .displayP3: return 1
        }
    }
}

struct Appearance: Codable, Sendable, Hashable {
    var appearance: String
    var value: String

    var darkLuminosity: Bool {
        appearance == "luminosity" && value == "dark"
    }

    static let dark = Appearance(appearance: "luminosity", value: "dark")
}

struct CatalogContents: Codable, Sendable {
    struct Info: Codable, Sendable {
        var version: Int
        var author: String
    }
    var info: Info
}

struct ImageSetContents: Codable, Sendable {
    struct Image: Codable, Sendable {
        var idiom: Idiom
        var scale: Scale?
        var filename: String?
        var appearances: [Appearance]?
        var displayGamut: Gamut?

        enum CodingKeys: String, CodingKey {
            case idiom, scale, filename, appearances
            case displayGamut = "display-gamut"
        }
    }
    var images: [Image]
    var info: CatalogContents.Info
}

struct AppIconContents: Codable, Sendable {
    struct Image: Codable, Sendable {
        var idiom: Idiom
        var size: String
        var scale: Scale?
        var filename: String?
        var role: String?
        var subtype: String?

        var pointSize: (Double, Double)? {
            let parts = size.split(separator: "x")
            guard parts.count == 2,
                  let w = Double(parts[0]),
                  let h = Double(parts[1]) else { return nil }
            return (w, h)
        }
    }
    var images: [Image]
    var info: CatalogContents.Info
}

struct ColorSetContents: Codable, Sendable {
    struct ColorEntry: Codable, Sendable {
        var idiom: Idiom
        var appearances: [Appearance]?
        var displayGamut: Gamut?
        var color: Color

        enum CodingKeys: String, CodingKey {
            case idiom, appearances, color
            case displayGamut = "display-gamut"
        }
    }

    struct Color: Codable, Sendable {
        var colorSpace: String
        var components: Components

        enum CodingKeys: String, CodingKey {
            case colorSpace = "color-space"
            case components
        }

        /// The color space ID a named color's body carries, as actool 27.0
        /// writes it: srgb 1, gray-gamma-22 2, display-p3 3, extended-srgb 4,
        /// extended-linear-srgb 5 (not the bitmap `Gamut.colorSpaceID`).
        /// Any other name is refused, as a missing `color-space` is (gray
        /// spaces have no `red` component and fail to decode before this).
        func colorSpaceID() throws -> UInt8 {
            switch colorSpace {
            case "srgb": return 1
            case "display-p3": return 3
            case "extended-srgb": return 4
            case "extended-linear-srgb": return 5
            default: throw XCAssetCompilerError.unsupportedColorSpace(colorSpace)
            }
        }

        struct Components: Codable, Sendable {
            var red: String
            var green: String
            var blue: String
            var alpha: String

            func asDoubles() throws -> (r: Double, g: Double, b: Double, a: Double) {
                func parse(_ s: String) throws -> Double {
                    if s.hasPrefix("0x") || s.hasPrefix("0X") {
                        let hex = String(s.dropFirst(2))
                        guard let n = UInt8(hex, radix: 16) else {
                            throw XCAssetCompilerError.invalidColorComponent(s)
                        }
                        return Double(n) / 255
                    }
                    // actool 27.0: a component without a decimal point is an
                    // 8-bit value ("255" is 1.0, "1" is 1/255); one with a
                    // decimal point is taken as is, through Float ("0.2" is
                    // 0.20000000298…, "1.2" stays 1.2 for extended ranges).
                    if let n = Int(s) { return Double(n) / 255 }
                    guard let n = Float(s) else {
                        throw XCAssetCompilerError.invalidColorComponent(s)
                    }
                    return Double(n)
                }
                return (try parse(red), try parse(green), try parse(blue), try parse(alpha))
            }
        }
    }

    var colors: [ColorEntry]
    var info: CatalogContents.Info
}
