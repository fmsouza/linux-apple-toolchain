import Foundation
import XlessCore

/// What `xcrun assetutil --info` says about the renditions of a compiled asset catalog (`Assets.car`), reduced to the
/// fields that change how a rendition draws. `BundleReport` carries one list per car of the bundle, so a reference
/// recorded from Xcode's build on a Mac can be compared with an xless build. assetutil exists on macOS only: elsewhere
/// the catalogs are not read (and not compared).
///
/// Compared: the fields in `renderingFields`. Not compared: how the pixels are stored or named (`Compression`, which
/// is deepmap2 for actool's images and lzfse for AssetKit's, both decoded by CoreUI; `SizeOnDisk`, `SHA1Digest`,
/// `NameIdentifier`, `RenditionName`) and actool's packed atlases of small images (`PackedImage`), which AssetKit
/// never writes. An AssetKit car that reports `Opaque: true` for a transparent PNG draws it on a black square; this is
/// the check that sees it.
public enum AssetCatalogReport {
    public static let renderingFields = ["AssetType", "Name", "Idiom", "Scale", "Appearance", "DisplayGamut", "Opaque",
                                         "Encoding", "ColorModel", "Colorspace", "BitsPerComponent", "PixelWidth",
                                         "PixelHeight", "Template Mode", "Color components", "Icon Index", "Sizes"]
    /// The fields that name a rendition in a difference: `car:<car>:<Name>/<Idiom>/<Scale>/<Appearance>/<AssetType>`.
    static let identityFields = ["Name", "Idiom", "Scale", "Appearance", "AssetType"]

    public static var isAvailable: Bool {
        #if os(macOS)
        return FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun")
        #else
        return false
        #endif
    }

    /// One line per rendition (`Field=value`, `|`-separated, in `renderingFields` order, absent fields left out), sorted.
    public static func renditions(car: URL) throws -> [String] {
        let out: ShellResult
        do { out = try Shell.run("/usr/bin/xcrun", ["assetutil", "--info", car.path], stage: .build) }
        catch let e as XlessError {
            throw XlessError(.build, "assetutil cannot read \(car.path): \(e.cause)", fix: "check that it is a compiled asset catalog")
        }
        return try renditions(assetutilJSON: Data(out.stdout.utf8), car: car.path)
    }

    static func renditions(assetutilJSON data: Data, car: String) throws -> [String] {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw XlessError(.build, "assetutil --info on \(car) did not print a JSON array", fix: "run `xcrun assetutil --info \(car)` by hand")
        }
        // The first entry describes the car itself (storage version, platform, authoring tool).
        return entries.dropFirst().filter { $0["AssetType"] as? String != "PackedImage" }.map(line).sorted()
    }

    static func line(_ rendition: [String: Any]) -> String {
        renderingFields.compactMap { f in rendition[f].map { "\(f)=\(BundleReport.canonical($0, top: true))" } }
            .joined(separator: "|")
    }

    static func identity(_ line: String) -> String {
        var fields: [String: String] = [:]
        for part in line.split(separator: "|") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            fields[String(part[..<eq])] = String(part[part.index(after: eq)...])
        }
        return identityFields.map { fields[$0] ?? "-" }.joined(separator: "/")
    }

    /// The renditions of every `.car` among `files` (bundle-relative paths), keyed by path.
    public static func catalogs(in bundle: URL, files: [String]) throws -> [String: [String]] {
        var out: [String: [String]] = [:]
        for f in files where f.hasSuffix(".car") {
            out[f] = try renditions(car: bundle.appendingPathComponent(f))
        }
        return out
    }

    /// Every `.car` under `directory`, by relative path (for `xless tauri compare --assets-only` on a directory that
    /// holds only the cars of a bundle built elsewhere).
    public static func carFiles(under directory: URL) -> [String] {
        let root = directory.resolvingSymlinksInPath().path
        guard let en = FileManager.default.enumerator(atPath: root) else { return [] }
        return en.compactMap { $0 as? String }.filter { $0.hasSuffix(".car") }.sorted()
    }

    /// One line per difference, keyed `car:<car>` (a car on one side only) or `car:<car>:<identity>`.
    public static func diff(reference: [String: [String]], actual: [String: [String]], allowed: Set<String>) -> [String] {
        var out: [String] = []
        func add(_ key: String, _ msg: String) { if !allowed.contains(key) { out.append("\(key) \(msg)") } }
        for car in Set(reference.keys).union(actual.keys).sorted() {
            guard let r = reference[car] else { add("car:\(car)", "not in reference"); continue }
            guard let a = actual[car] else { add("car:\(car)", "missing from actual"); continue }
            let rg = Dictionary(grouping: r, by: identity), ag = Dictionary(grouping: a, by: identity)
            for id in Set(rg.keys).union(ag.keys).sorted() {
                let rl = (rg[id] ?? []).sorted(), al = (ag[id] ?? []).sorted()
                if rl == al { continue }
                if rl.isEmpty { add("car:\(car):\(id)", "not in reference: \(al.joined(separator: " ; "))") }
                else if al.isEmpty { add("car:\(car):\(id)", "missing from actual: \(rl.joined(separator: " ; "))") }
                else { add("car:\(car):\(id)", "reference=\(rl.joined(separator: " ; ")) actual=\(al.joined(separator: " ; "))") }
            }
        }
        return out
    }
}
