import Foundation
import Crypto
import XlessCore

/// The Xcode `xless setup` builds images from: a downloaded `.xip`, identified by its content (SHA-256 against the
/// supported-Xcode table; the file name is ignored), or an `Xcode.app`, identified by its `Contents/version.plist`.
/// Nothing is executed and the archive is never expanded here: xtool reads it inside the base image.
public enum XcodeSource {
    public enum Kind: Equatable, Sendable { case xip, app }
    public typealias Identified = (xcode: KnownXcode, kind: Kind, url: URL)

    public static func identify(path: String, known: [KnownXcode], cwd: URL, home: URL) throws -> Identified {
        let url = absolute(path, cwd: cwd, home: home)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw XlessError(.sdk, "\(url.path) does not exist", fix: "pass the path to an Xcode .xip or Xcode.app with --xcode")
        }
        if isDir.boolValue {
            let plist = try? Plist.read(url.appendingPathComponent("Contents/version.plist"), stage: .sdk)
            if let build = plist?["ProductBuildVersion"] as? String, let x = known.first(where: { $0.build == build }) {
                return (x, .app, url)
            }
        } else {
            let hashes = Set(known.flatMap(\.xipSHA256).map { $0.lowercased() })
            if !hashes.isEmpty {
                let sum = try sha256(of: url)
                if let x = known.first(where: { $0.xipSHA256.contains { $0.lowercased() == sum } }) { return (x, .xip, url) }
            }
        }
        throw unsupported(url.path, known: known)
    }

    /// `~` and `~/…` against `home`, a relative path against `cwd`; `.` and `..` resolved, symlinks kept.
    public static func absolute(_ path: String, cwd: URL, home: URL) -> URL {
        var p = path
        if p == "~" { p = home.path } else if p.hasPrefix("~/") { p = home.path + String(p.dropFirst(1)) }
        let url = p.hasPrefix("/") ? URL(fileURLWithPath: p) : cwd.appendingPathComponent(p)
        return url.standardizedFileURL
    }

    public static func unsupported(_ path: String, known: [KnownXcode]) -> XlessError {
        let list = known.map { "Xcode \($0.shortVersion) (\($0.build))" }.joined(separator: ", ")
        let versions = known.map(\.shortVersion)
        let spoken = versions.count <= 1 ? versions.joined()
            : versions.dropLast().joined(separator: ", ") + " or " + versions.last!
        return XlessError(.sdk, "\(path) is not a supported Xcode (supported: \(list))",
                          fix: "download the Universal Xcode \(spoken) .xip from https://developer.apple.com/download/all/ (free Apple ID)")
    }

    /// The file's SHA-256 (lowercase hex), read in chunks: an Xcode .xip is several GB.
    public static func sha256(of url: URL, chunkSize: Int = 8 << 20) throws -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else {
            throw XlessError(.sdk, "cannot read \(url.path)", fix: "check the file's permissions")
        }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do { chunk = try h.read(upToCount: chunkSize) } catch {
                throw XlessError(.sdk, "cannot read \(url.path): \(error)", fix: "check the file and the disk")
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
