// Usage: swift scripts/make-sample-icon.swift <out.png>
// Draws a 1024x1024 opaque (no alpha) gradient icon. App Store rejects icons with alpha (ITMS-90717).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let colors = [CGColor(red: 0.05, green: 0.35, blue: 0.95, alpha: 1), CGColor(red: 0.45, green: 0.1, blue: 0.85, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fill(CGRect(x: 312, y: 312, width: 400, height: 400))
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
precondition(CGImageDestinationFinalize(dest))
