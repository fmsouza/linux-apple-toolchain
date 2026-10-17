import Foundation
import Testing
@testable import AssetKit

/// End-to-end CI gate: compile the bundled fixture catalog, then shell out to
/// Apple's `assetutil --info` and assert it parses our `Assets.car` cleanly
/// with the expected rendition fields. macOS-only; the test is skipped where
/// `xcrun` is unavailable.
///
/// This is the durable verification for CoreUI format compatibility. The
/// underlying byte format drifts across Xcode releases (see
/// `Sources/AssetKit/CAR/KeyFormat.swift`), so this test will catch
/// the regression on a future macOS runner before users do.
@Suite("assetutil parse gate")
struct AssetutilParseTests {

    @Test(
        "assetutil parses the compiled Assets.car and reports expected fields",
        .enabled(if: ProcessLauncher.isAvailable)
    )
    func parsesCleanly() async throws {
        let bundle = Bundle.module
        guard let fixtureURL = bundle.url(
            forResource: "Test",
            withExtension: "xcassets",
            subdirectory: "Fixtures"
        ) else {
            Issue.record("Fixtures/Test.xcassets missing from test bundle")
            return
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcasset-assetutil-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let compiler = XCAssetCompiler(
            deploymentTarget: "16.0",
            svgRasterizer: StubSVGRasterizer()
        )
        let result = try await compiler.compile(catalog: fixtureURL)
        let carURL = scratch.appendingPathComponent("Assets.car")
        try result.carData.write(to: carURL)

        let invocation = try ProcessLauncher.run(
            executable: "/usr/bin/xcrun",
            arguments: ["assetutil", "--info", carURL.path]
        )

        if invocation.exitCode != 0 {
            let stderr = String(decoding: invocation.stderr, as: UTF8.self)
            Issue.record("""
            xcrun assetutil exited \(invocation.exitCode):
            \(stderr)
            """)
            return
        }

        guard let entries = try JSONSerialization.jsonObject(with: invocation.stdout) as? [[String: Any]] else {
            Issue.record("assetutil output did not parse as a JSON array of objects")
            return
        }

        try assertHeader(entries.first)

        let renditions = entries.dropFirst().filter { $0["AssetType"] as? String == "Icon Image" }
        #expect(renditions.count == 2, "expected two raw Icon Image renditions (@2x and @3x)")

        for (i, rendition) in renditions.enumerated() {
            #expect(rendition["Idiom"] as? String == "phone", "rendition[\(i)] idiom")
            #expect(rendition["Name"] as? String == "AppIcon", "rendition[\(i)] name")
            #expect(rendition["Encoding"] as? String == "ARGB", "rendition[\(i)] encoding")
            #expect(rendition["BitsPerComponent"] as? Int == 8, "rendition[\(i)] BitsPerComponent")
            #expect(rendition["ColorModel"] as? String == "RGB", "rendition[\(i)] ColorModel")
            #expect((rendition["Colorspace"] as? String)?.lowercased() == "srgb", "rendition[\(i)] Colorspace")
        }

        let twoX = renditions.first { ($0["Scale"] as? Int) == 2 }
        let threeX = renditions.first { ($0["Scale"] as? Int) == 3 }
        #expect(twoX?["PixelWidth"] as? Int == 120)
        #expect(twoX?["PixelHeight"] as? Int == 120)
        #expect(twoX?["RenditionName"] as? String == "icon@2x.png")
        #expect(threeX?["PixelWidth"] as? Int == 180)
        #expect(threeX?["PixelHeight"] as? Int == 180)
        #expect(threeX?["RenditionName"] as? String == "icon@3x.png")
    }

    /// `assetutil --info` reads cars that App Store processing rejects (ITMS-90562). `--validate-file` checks
    /// the bitmap index and key format; thinning (what App Store processing does per device) opens the BOM for
    /// writing, which needs a well-formed block index and free list.
    @Test(
        "assetutil validates and thins the compiled Assets.car",
        .enabled(if: ProcessLauncher.isAvailable)
    )
    func validatesAndThins() async throws {
        let fixtureURL = try #require(Bundle.module.url(forResource: "Test", withExtension: "xcassets", subdirectory: "Fixtures"))
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcasset-validate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // The fixture plus a colorset, so every rendition body kind is in the car.
        let catalog = scratch.appendingPathComponent("Test.xcassets")
        try FileManager.default.copyItem(at: fixtureURL, to: catalog)
        let colorSet = catalog.appendingPathComponent("Accent.colorset")
        try FileManager.default.createDirectory(at: colorSet, withIntermediateDirectories: true)
        try Data("""
        { "info": { "version": 1, "author": "xcode" }, "colors": [ { "idiom": "universal",
          "color": { "color-space": "srgb", "components": { "red": "0.5", "green": "0.5", "blue": "0.5", "alpha": "1.0" } } } ] }
        """.utf8).write(to: colorSet.appendingPathComponent("Contents.json"))

        let result = try await XCAssetCompiler(deploymentTarget: "16.0", svgRasterizer: StubSVGRasterizer()).compile(catalog: catalog)
        let carURL = scratch.appendingPathComponent("Assets.car")
        let thinURL = scratch.appendingPathComponent("thin.car")
        try result.carData.write(to: carURL)

        let validate = try ProcessLauncher.run(executable: "/usr/bin/xcrun", arguments: ["assetutil", "--validate-file", carURL.path])
        #expect(validate.exitCode == 0, "\(String(decoding: validate.stdout + validate.stderr, as: UTF8.self))")

        // assetutil exits 0 even when it cannot read the input, so check for the output file.
        let thin = try ProcessLauncher.run(executable: "/usr/bin/xcrun", arguments: [
            "assetutil", "-i", "phone", "-s", "3", "-p", "srgb", "-M", "4", "-g", "MTL5,1", "-r", "2026",
            "-o", thinURL.path, carURL.path,
        ])
        #expect(FileManager.default.fileExists(atPath: thinURL.path), "\(String(decoding: thin.stdout + thin.stderr, as: UTF8.self))")
    }

    private func assertHeader(_ header: [String: Any]?) throws {
        guard let header else {
            Issue.record("assetutil output missing header entry")
            return
        }
        #expect(header["StorageVersion"] as? Int == 17, "StorageVersion mismatch")
        #expect(header["Platform"] as? String == "ios", "Platform mismatch")
        #expect(header["SchemaVersion"] as? Int == 2, "SchemaVersion mismatch")
    }
}

enum ProcessLauncher {
    struct Invocation {
        var exitCode: Int32
        var stdout: Data
        var stderr: Data
    }

    static var isAvailable: Bool {
        #if os(macOS)
        return FileManager.default.fileExists(atPath: "/usr/bin/xcrun")
        #else
        return false
        #endif
    }

    static func run(executable: String, arguments: [String]) throws -> Invocation {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return Invocation(
            exitCode: process.terminationStatus,
            stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderr.fileHandleForReading.readDataToEndOfFile()
        )
    }
}
