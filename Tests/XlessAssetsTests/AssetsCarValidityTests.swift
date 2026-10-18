import Testing
import Foundation
@testable import XlessAssets
@testable import XlessCore

// App Store processing rejected an Assets.car that `assetutil --info` read fine (ITMS-90562 "not a valid Asset
// Catalog file"). These tests check the two invariants that car broke, straight from the bytes, and on macOS run
// the checks Apple's tools apply: `assetutil --validate-file` and app thinning.

/// Minimal read-only Assets.car (BOM container) reader for tests.
struct CARFile {
    let data: Data
    let indexOffset: Int, indexLength: Int
    let blocks: [(addr: Int, len: Int)]
    let vars: [String: Int]

    init(_ data: Data) throws {
        self.data = Data(data)
        let d = self.data
        func be32(_ o: Int) -> Int { Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3]) }
        try #require(d.count > 32 && d.prefix(8) == Data("BOMStore".utf8))
        let index = be32(0x10), varsOffset = be32(0x18)
        indexOffset = index; indexLength = be32(0x14)
        blocks = (0..<be32(index)).map { (be32(index + 4 + 8 * $0), be32(index + 8 + 8 * $0)) }
        var vars: [String: Int] = [:], p = varsOffset + 4
        for _ in 0..<be32(varsOffset) {
            let n = Int(d[p + 4])
            vars[String(decoding: d[(p + 5)..<(p + 5 + n)], as: UTF8.self)] = be32(p)
            p += 5 + n
        }
        self.vars = vars
    }

    func be32(_ o: Int) -> Int { Int(data[o]) << 24 | Int(data[o + 1]) << 16 | Int(data[o + 2]) << 8 | Int(data[o + 3]) }
    func block(_ id: Int) -> Data { Data(data[blocks[id].addr..<(blocks[id].addr + blocks[id].len)]) }

    /// Leaf entries of the BOM tree named `variable`: (key block or inline key, value block).
    func tree(_ variable: String) throws -> [(key: Int, value: Data)] {
        let header = block(try #require(vars[variable]))
        let leafID = Int(header[8]) << 24 | Int(header[9]) << 16 | Int(header[10]) << 8 | Int(header[11])
        let leaf = blocks[leafID].addr
        let count = Int(data[leaf + 2]) << 8 | Int(data[leaf + 3])
        return (0..<count).map { (be32(leaf + 16 + 8 * $0), block(be32(leaf + 12 + 8 * $0))) }
    }
}

func le16s(_ d: Data) -> [Int] { stride(from: 0, to: d.count - 1, by: 2).map { Int(d[d.startIndex + $0]) | Int(d[d.startIndex + $0 + 1]) << 8 } }
func le32s(_ d: Data) -> [UInt32] {
    stride(from: 0, to: d.count - 3, by: 4).map { i in (0..<4).reduce(UInt32(0)) { $0 | UInt32(d[d.startIndex + i + $1]) << (8 * $1) } }
}

/// HelloShip's catalog: a single-size 1024 app icon and one sRGB colorset.
func helloShipLikeCatalog() throws -> URL {
    let root = try singleSizeCatalog(icon: solidPNG(256, r: 1, g: 2, b: 3))
    let color = root.appendingPathComponent("AccentBlue.colorset")
    try FileManager.default.createDirectory(at: color, withIntermediateDirectories: true)
    try Data(#"{"colors":[{"color":{"color-space":"srgb","components":{"alpha":"1.000","blue":"0.950","green":"0.350","red":"0.050"}},"idiom":"universal"}],"info":{"author":"xcode","version":1}}"#.utf8)
        .write(to: color.appendingPathComponent("Contents.json"))
    return root
}

func compiledIOSCar() async throws -> Data {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("in-\(UUID())/X.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try Plist.write(["CFBundleExecutable": "X", "UIDeviceFamily": [1, 2]], to: app.appendingPathComponent("Info.plist"), stage: .assets)
    let yaml = "bundleID: a.b\nteamID: ABCDE12345\nversion: \"1\"\nbuild: 1\nplatforms:\n  ios: { minimumOS: \"17.0\", product: X }\nassets: \(try helloShipLikeCatalog().path)\n"
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID())")
    let r = try await AssetsStage.run(input: app, outputDir: out, platform: .ios, config: ProjectConfig.parse(yaml: yaml), project: URL(fileURLWithPath: "/"), profile: testProfile())
    return try Data(contentsOf: r.appendingPathComponent("Assets.car"))
}

/// libBOM (which CoreUI uses to open a car for writing, e.g. when App Store processing thins it) reads a free list
/// right after the block table, inside the index range. Without it the car opens read-only but not for thinning.
@Test func iosCarBOMIndexEndsWithFreeList() async throws {
    let car = try CARFile(await compiledIOSCar())
    let freeList = car.indexOffset + 4 + 8 * car.blocks.count
    try #require(freeList + 4 <= car.indexOffset + car.indexLength, "no free list inside the BOM index range")
    let free = car.be32(freeList)
    #expect(freeList + 4 + 8 * free <= car.indexOffset + car.indexLength)
}

/// BITMAPKEYS holds, per asset name, which values of each KEYFORMAT attribute its renditions use (bit v set for
/// value v); appearance, identifier, element and part are unconstrained (-1). Derived from actool 27.0 output and
/// from `assetutil --update-bitmap`; `assetutil --validate-file` reports "invalid bitmapindex" otherwise.
@Test func iosCarBitmapKeysDescribeEveryAssetsRenditions() async throws {
    let car = try CARFile(await compiledIOSCar())
    let format = le32s(car.block(try #require(car.vars["KEYFORMAT"])))   // 'kfmt', version, count, tokens…
    let tokens = Array(format[3..<(3 + Int(format[2]))])
    let identifierSlot = try #require(tokens.firstIndex(of: 17))
    let keys = try car.tree("RENDITIONS").map { le16s(car.block($0.key)) }
    let names = try car.tree("FACETKEYS").map { facet -> Int in
        let pairs = le16s(facet.value)       // hotspot x, y, count, (attribute, value)…
        return try #require(stride(from: 3, to: 3 + 2 * pairs[2], by: 2).first { pairs[$0] == 17 }.map { pairs[$0 + 1] })
    }
    let bitmapKeys = try car.tree("BITMAPKEYS")
    #expect(Set(bitmapKeys.map(\.key)) == Set(names), "one BITMAPKEYS entry per asset name")
    for (identifier, descriptor) in bitmapKeys {
        let mine = keys.filter { $0[identifierSlot] == identifier }
        let masks = tokens.enumerated().map { slot, attribute -> UInt32 in
            [7, 17, 1, 2].contains(attribute) ? .max : mine.reduce(0) { $0 | 1 << UInt32($1[slot]) }
        }
        #expect(le32s(descriptor) == [1, 0, UInt32(4 + 4 * tokens.count), UInt32(tokens.count)] + masks, "BITMAPKEYS for \(identifier)")
    }
}

#if os(macOS)
private func assetutil(_ args: [String]) throws -> (status: Int32, output: String) {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    p.arguments = ["assetutil"] + args
    p.standardOutput = pipe; p.standardError = pipe
    try p.run()
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: out, as: UTF8.self))
}

private let hasAssetutil = (try? assetutil(["--version"]).status == 0) ?? false

@Test(.enabled(if: hasAssetutil)) func iosCarPassesAssetutilValidationAndThinning() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("car-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let car = dir.appendingPathComponent("Assets.car"), thin = dir.appendingPathComponent("thin.car")
    try await compiledIOSCar().write(to: car)
    let validate = try assetutil(["--validate-file", car.path])
    #expect(validate.status == 0, "assetutil --validate-file: \(validate.output)")
    // App thinning, as App Store processing does per device; assetutil exits 0 even when it cannot read the car.
    let thinning = try assetutil(["-i", "phone", "-s", "3", "-p", "srgb", "-M", "4", "-g", "MTL5,1", "-r", "2026", "-o", thin.path, car.path])
    #expect(FileManager.default.fileExists(atPath: thin.path), "assetutil thinning: \(thinning.output)")
}
#endif
