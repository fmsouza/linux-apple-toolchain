import Foundation

/// `ditto <source> <destination>` on Linux (`xless shim ditto`). CocoaPods' "Copy generated compatibility header"
/// phase of every Swift pod copies the generated `-Swift.h`, the module map and the umbrella header with it; without
/// `ditto` those phases fail silently (they do not `set -e`) and the pod's module map is left with only its Swift
/// submodule. Behaviour taken black-box from macOS's `ditto` (docs/research/react-native-ios-contract.md, "Gate G3/G4"):
/// - a directory source: its contents are merged into the destination (created with its parents); symbolic links
///   inside are copied as links;
/// - a file source (a symbolic link is followed): copied to the destination path (parents created), or into an
///   existing destination directory under the name of the file the link resolves to;
/// - permissions and modification times are kept.
/// Options and more than one source are refused with exit 70 and the argv, as `XcrunShim`.
public enum DittoShim {
    public struct Unsupported: Error, CustomStringConvertible, Equatable {
        public let argv: [String]
        public let reason: String
        public var description: String { "ditto shim: unsupported call (\(reason)): ditto \(argv.joined(separator: " "))" }
    }

    public static func run(_ args: [String], fileManager fm: FileManager = .default) throws {
        guard args.count == 2, !args.contains(where: { $0.hasPrefix("-") }) else {
            throw Unsupported(argv: args, reason: "only `ditto <source> <destination>` is supported")
        }
        let source = URL(fileURLWithPath: args[0]), destination = URL(fileURLWithPath: args[1])
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else {
            throw XlessError(.build, "ditto: \(source.path): No such file or directory", fix: "the build phase's input is missing")
        }
        if isDir.boolValue {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try merge(source, into: destination, fm)
            try copyAttributes(from: source, to: destination, fm)
            return
        }
        let resolved = source.resolvingSymlinksInPath()
        var destIsDir: ObjCBool = false
        let target = fm.fileExists(atPath: destination.path, isDirectory: &destIsDir) && destIsDir.boolValue
            ? destination.appendingPathComponent(resolved.lastPathComponent) : destination
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try copyFile(resolved, to: target, fm)
    }

    static func merge(_ dir: URL, into dest: URL, _ fm: FileManager) throws {
        for name in try fm.contentsOfDirectory(atPath: dir.path).sorted() {
            let src = dir.appendingPathComponent(name), dst = dest.appendingPathComponent(name)
            let attrs = try fm.attributesOfItem(atPath: src.path)
            switch attrs[.type] as? FileAttributeType {
            case .typeSymbolicLink?:
                if (try? fm.attributesOfItem(atPath: dst.path)) != nil { try fm.removeItem(at: dst) }
                try fm.createSymbolicLink(atPath: dst.path, withDestinationPath: try fm.destinationOfSymbolicLink(atPath: src.path))
            case .typeDirectory?:
                try fm.createDirectory(at: dst, withIntermediateDirectories: true)
                try merge(src, into: dst, fm)
                try copyAttributes(from: src, to: dst, fm)
            case .typeRegular?:
                try copyFile(src, to: dst, fm)
            default:
                throw XlessError(.build, "ditto: \(src.path) is not a file, directory or symbolic link", fix: "the build phase's input is unexpected")
            }
        }
    }

    static func copyFile(_ src: URL, to dst: URL, _ fm: FileManager) throws {
        if (try? fm.attributesOfItem(atPath: dst.path)) != nil { try fm.removeItem(at: dst) }
        try fm.copyItem(at: src, to: dst)
        try copyAttributes(from: src, to: dst, fm)
    }

    static func copyAttributes(from src: URL, to dst: URL, _ fm: FileManager) throws {
        let a = try fm.attributesOfItem(atPath: src.path)
        var keep: [FileAttributeKey: Any] = [:]
        if let p = a[.posixPermissions] { keep[.posixPermissions] = p }
        if let m = a[.modificationDate] { keep[.modificationDate] = m }
        try fm.setAttributes(keep, ofItemAtPath: dst.path)
    }
}
