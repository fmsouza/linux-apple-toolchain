import Foundation
import XlessCore
import XlessMachO

public struct BinaryReport: Codable, Sendable, Equatable { public var path: String; public var buildVersions: [String] }
public struct InspectReport: Codable, Sendable { public var infoPlist: [String: String]; public var binaries: [BinaryReport] }

public enum Inspector {
    public static func report(bundle: URL, platform: Platform) throws -> InspectReport {
        let info = try Plist.read(bundle.appendingPathComponent(BundleLayout(platform: platform).infoPlist), stage: .finalize)
        var flat: [String: String] = [:]
        for (k, v) in info {
            if let s = v as? String { flat[k] = s }
            else if let data = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .fragmentsAllowed]) {
                flat[k] = String(decoding: data, as: UTF8.self)
            } else { flat[k] = "\(v)" }
        }
        let base = bundle.standardizedFileURL.path
        var bins: [BinaryReport] = []
        for f in Files.regularFiles(under: bundle) {
            guard let d = try? Data(contentsOf: f), (try MachO.containsLoadableImage(d)) else { continue }
            let versions = try MachO.buildVersions(in: d).map {
                "platform=\($0.platform) minos=\(MachO.decodeVersion($0.minos)) sdk=\(MachO.decodeVersion($0.sdk))"
            }
            bins.append(.init(path: String(f.standardizedFileURL.path.dropFirst(base.count + 1)), buildVersions: versions))
        }
        return InspectReport(infoPlist: flat, binaries: bins.sorted { $0.path < $1.path })
    }
}
