import Foundation
import XlessCore
import XlessMachO

public struct ExecutableReport: Codable, Equatable, Sendable {
    public var platform: UInt32
    public var minos: String
    public var linkedLibraries: [String]
    public var rpaths: [String]

    public init(platform: UInt32, minos: String, linkedLibraries: [String], rpaths: [String]) {
        self.platform = platform; self.minos = minos; self.linkedLibraries = linkedLibraries; self.rpaths = rpaths
    }

    static func read(_ url: URL) throws -> ExecutableReport {
        let data = try Data(contentsOf: url)
        let bv = try MachO.buildVersions(in: data).first
        return ExecutableReport(platform: bv?.platform ?? 0, minos: bv.map { MachO.decodeVersion($0.minos) } ?? "",
                                linkedLibraries: try MachO.linkedLibraries(in: data), rpaths: try MachO.rpaths(in: data))
    }
}

/// Platform-independent description of a built .app, used to compare an xless build against an Xcode-built reference.
public struct BundleReport: Codable, Equatable, Sendable {
    public var files: [String]
    public var infoPlist: [String: String]
    public var executable: ExecutableReport
    public var frameworks: [String: ExecutableReport]

    static let volatilePlistKeys: Set<String> = ["BuildMachineOSBuild", "DTCompiler", "DTPlatformBuild", "DTSDKBuild",
                                                 "DTXcode", "DTXcodeBuild", "CFBundleVersion"]

    public static func make(app: URL) throws -> BundleReport {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: app.path, isDirectory: &isDir), isDir.boolValue else {
            throw XlessError(.build, "no bundle at \(app.path)", fix: "pass the path of a built .app directory")
        }
        let root = app.resolvingSymlinksInPath()
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw XlessError(.build, "cannot read bundle at \(app.path)", fix: "check the directory permissions")
        }
        var files: [String] = []
        for case let url as URL in en {
            let full = url.path.hasPrefix(root.path + "/") ? url.path : url.resolvingSymlinksInPath().path
            let rel = String(full.dropFirst(root.path.count + 1))
            if rel == "_CodeSignature" || rel.hasPrefix("_CodeSignature/") || rel.hasSuffix("/_CodeSignature")
                || rel.contains("/_CodeSignature/") || rel.hasSuffix("embedded.mobileprovision") { continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            files.append(rel)
        }
        files.sort()

        let plistURL = root.appendingPathComponent("Info.plist")
        guard let plistData = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            throw XlessError(.build, "no readable Info.plist in \(app.path)", fix: "pass the path of a built .app directory")
        }
        var info: [String: String] = [:]
        for (k, v) in plist where !volatilePlistKeys.contains(k) { info[k] = canonical(v, top: true) }

        guard let exeName = plist["CFBundleExecutable"] as? String else {
            throw XlessError(.build, "Info.plist in \(app.path) has no CFBundleExecutable", fix: "pass the path of a built .app directory")
        }
        let exe: ExecutableReport
        do { exe = try ExecutableReport.read(root.appendingPathComponent(exeName)) }
        catch { throw XlessError(.build, "cannot read executable \(exeName) in \(app.path): \(error)", fix: "pass the path of a built .app directory") }

        var fws: [String: ExecutableReport] = [:]
        let fwDir = root.appendingPathComponent("Frameworks")
        for name in ((try? fm.contentsOfDirectory(atPath: fwDir.path)) ?? []).sorted() where name.hasSuffix(".framework") {
            let bin = fwDir.appendingPathComponent(name).appendingPathComponent(String(name.dropLast(".framework".count)))
            guard let data = try? Data(contentsOf: bin) else { continue }
            let isImage: Bool
            do { isImage = try MachO.containsLoadableImage(data) }
            catch { throw XlessError(.build, "cannot read framework \(name) in \(app.path): \(error)", fix: "pass the path of a built .app directory") }
            guard isImage else { continue }   // static archives (also fat-wrapped) are not reported
            do { fws[name] = try ExecutableReport.read(bin) }
            catch { throw XlessError(.build, "cannot read framework \(name) in \(app.path): \(error)", fix: "pass the path of a built .app directory") }
        }
        return BundleReport(files: files, infoPlist: info, executable: exe, frameworks: fws)
    }

    /// Platform-independent rendering of a plist value: sorted dictionary keys, explicit scalar forms.
    /// A top-level string is verbatim; nested strings are quoted. Darwin and Linux Foundation decode
    /// bool/number/date differently, so every scalar is classified explicitly.
    static func canonical(_ v: Any, top: Bool = false) -> String {
        if let s = v as? String { return top ? s : quote(s) }
        if let d = v as? [String: Any] {
            return "{" + d.keys.sorted().map { "\(quote($0)):\(canonical(d[$0]!))" }.joined(separator: ",") + "}"
        }
        if let a = v as? [Any] { return "[" + a.map { canonical($0) }.joined(separator: ",") + "]" }
        if let dt = v as? Date {
            let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")!
            return "date(\(f.string(from: dt)))"
        }
        if let d = v as? Data { return "data(\(d.base64EncodedString()))" }
        if type(of: v) == Bool.self, let b = v as? Bool { return b ? "true" : "false" }
        if let n = v as? NSNumber {
            switch String(cString: n.objCType) {
            case "c", "B": return n.boolValue ? "true" : "false"   // plist integers are 64-bit ("q"/"Q"), never "c"
            case "f", "d": return "\(n.doubleValue)"
            case "Q": return "\(n.uint64Value)"
            default: return "\(n.int64Value)"
            }
        }
        return String(describing: v)
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Deterministic JSON (sorted keys, pretty printed).
    public func json() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    /// One line per difference, each starting with its key (`file:`, `plist:`, `lib:`, `rpath:`, `exe:`, `framework:`).
    public static func diff(reference: BundleReport, actual: BundleReport, allowed: Set<String>) -> [String] {
        var out: [String] = []
        func add(_ key: String, _ msg: String) { if !allowed.contains(key) { out.append("\(key) \(msg)") } }

        let rf = Set(reference.files), af = Set(actual.files)
        for f in rf.subtracting(af).sorted() { add("file:\(f)", "missing from actual") }
        for f in af.subtracting(rf).sorted() { add("file:\(f)", "not in reference") }

        for k in Set(reference.infoPlist.keys).union(actual.infoPlist.keys).sorted() {
            let r = reference.infoPlist[k], a = actual.infoPlist[k]
            if r != a { add("plist:\(k)", "reference=\(r ?? "<absent>") actual=\(a ?? "<absent>")") }
        }

        func libs(_ r: BundleReport) -> Set<String> {
            Set(r.executable.linkedLibraries).union(r.frameworks.values.flatMap(\.linkedLibraries))
        }
        let rl = libs(reference), al = libs(actual)
        for l in rl.subtracting(al).sorted() { add("lib:\(l)", "missing from actual") }
        for l in al.subtracting(rl).sorted() { add("lib:\(l)", "not in reference") }

        func rpaths(_ r: BundleReport) -> Set<String> {
            Set(r.executable.rpaths).union(r.frameworks.values.flatMap(\.rpaths))
        }
        let rr = rpaths(reference), ar = rpaths(actual)
        for p in rr.subtracting(ar).sorted() { add("rpath:\(p)", "missing from actual") }
        for p in ar.subtracting(rr).sorted() { add("rpath:\(p)", "not in reference") }

        if reference.executable.platform != actual.executable.platform {
            add("exe:platform", "reference=\(reference.executable.platform) actual=\(actual.executable.platform)")
        }
        if reference.executable.minos != actual.executable.minos {
            add("exe:minos", "reference=\(reference.executable.minos) actual=\(actual.executable.minos)")
        }
        for n in Set(reference.frameworks.keys).union(actual.frameworks.keys).sorted() {
            let r = reference.frameworks[n], a = actual.frameworks[n]
            if r == nil { add("framework:\(n)", "not in reference") }
            else if a == nil { add("framework:\(n)", "missing from actual") }
            else if r!.platform != a!.platform || r!.minos != a!.minos {
                add("framework:\(n)", "reference=\(r!.platform)/\(r!.minos) actual=\(a!.platform)/\(a!.minos)")
            }
        }
        return out
    }

    /// Allow-file format: one key per line; blank lines and `#` comments are ignored.
    public static func parseAllow(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }
}
