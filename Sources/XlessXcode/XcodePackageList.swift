import Foundation
import XlessCore

/// The Swift packages a workspace's projects reference, for resolving them before the PIF is written: each must be
/// checked out in a directory named by its identity and dumped with `swift package dump-pif`
/// (`XcodebuildShim.dumpPIFArguments`), then passed to the PIF writer (`ResolvedPackage`).
public enum XcodePackageList {
    /// One line per package, sorted by identity and deduplicated: `identity<TAB>url<TAB>revision` for a remote
    /// package pinned to a revision, `identity<TAB>path` for a local one (relative to its project's directory).
    /// Version, branch and range requirements need SwiftPM's resolution, which xless does not do: refused.
    public static func lines(_ workspace: Workspace) throws -> [String] {
        var out: [String: String] = [:]
        for project in workspace.projects {
            for ref in project.packageReferences {
                let line: String
                switch ref.kind {
                case .remote(let url, let requirement):
                    guard requirement["kind"] == "revision", let revision = requirement["revision"], !revision.isEmpty else {
                        let described = requirement.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                        throw XlessError(.prepare, "Swift package \(url) in \(project.path.lastPathComponent) has requirement \(described); only revision pins are supported",
                                         fix: "pin the package to a revision in the Xcode project")
                    }
                    line = "\(ref.identity)\t\(url)\t\(revision)"
                case .local(let path):
                    line = "\(ref.identity)\t\(project.directory.appendingPathComponent(path).standardizedFileURL.path)"
                }
                if let existing = out[ref.identity], existing != line {
                    throw XlessError(.prepare, "two different Swift packages have the identity \(ref.identity): \(existing) and \(line)",
                                     fix: "reference one package per identity")
                }
                out[ref.identity] = line
            }
        }
        return out.keys.sorted().map { out[$0]! }
    }
}
