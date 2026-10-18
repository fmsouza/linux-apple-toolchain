import Foundation
import XlessCore

/// The file-writing half of `xless storyboard compile`; the command is a thin wrapper around it.
public enum StoryboardCompileRunner {
    /// Maps the CLI flags to compile options, with CLI-worded refusals (before any file is read).
    public static func options(devices: [String], minimumDeploymentTarget: String) throws -> IBCompileOptions {
        for d in devices where d != "iphone" && d != "ipad" {
            throw XlessError(.ib, "unknown --target-device \(d) (expected iphone or ipad)", fix: "pass --target-device iphone and/or --target-device ipad")
        }
        let unique = Set(devices)
        guard unique.contains("iphone") else {
            throw XlessError(.ib, unique.isEmpty ? "no --target-device given" : "--target-device ipad alone is not supported (verified: iphone, or ipad + iphone)",
                             fix: "pass --target-device iphone, or both --target-device iphone --target-device ipad")
        }
        guard let v = DottedVersion(minimumDeploymentTarget), v >= DottedVersion("15.0")!, v.major <= 27 else {
            throw XlessError(.ib, "--minimum-deployment-target \(minimumDeploymentTarget) is not supported (expected 15.0 to 27.x)",
                             fix: "pass a numeric iOS version between 15.0 and 27.x, e.g. 16.0")
        }
        return IBCompileOptions(targetDevices: Array(unique), minimumDeploymentTarget: minimumDeploymentTarget)
    }

    /// Compiles `input` into the `.storyboardc` directory `out`. The files are staged in a sibling directory and
    /// swapped in only after every write succeeded, so a failure leaves any existing `out` untouched.
    /// Warnings go to `warn`, one call per line (stderr by default).
    /// `profile` is the Xcode whose ibtool output is reproduced. `compile` is injectable for tests (default: the
    /// compiler with `profile`); the real compiler currently emits no warnings.
    @discardableResult
    public static func run(input: URL, out: URL, options: IBCompileOptions, profile: XcodeToolsProfile, force: Bool,
                           compile: ((IBDocument, IBCompileOptions) throws -> IBCompileResult)? = nil,
                           warn: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) throws -> IBCompileResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: out.path, isDirectory: &isDir) {
            guard force else { throw XlessError(.ib, "\(out.path) already exists", fix: "pass --force to replace it") }
            guard isDir.boolValue, out.pathExtension == "storyboardc" else {
                throw XlessError(.ib, "\(out.path) exists and is not a .storyboardc directory; refusing to replace it", fix: "choose another --out, or remove it yourself")
            }
        }
        let parent = out.deletingLastPathComponent()
        guard fm.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue else {
            throw XlessError(.ib, "cannot write \(out.path): the directory \(parent.path) does not exist", fix: "create it first, or choose another --out")
        }
        let doc = try StoryboardParser.parse(url: input)
        let result = try compile.map { try $0(doc, options) } ?? StoryboardCompiler.compile(doc, options: options, profile: profile)
        try write(result.files, to: out)
        for w in result.warnings { warn(w) }
        return result
    }

    private static func write(_ files: [String: Data], to out: URL) throws {
        let fm = FileManager.default
        let staging = out.deletingLastPathComponent().appendingPathComponent(".\(out.lastPathComponent).\(UUID().uuidString).partial", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            for (name, data) in files.sorted(by: { $0.key < $1.key }) {
                try data.write(to: staging.appendingPathComponent(name))
            }
            if fm.fileExists(atPath: out.path) {
                _ = try fm.replaceItemAt(out, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: out)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw XlessError(.ib, "cannot write \(out.path): \(error.localizedDescription)", fix: "check that the parent directory exists and is writable")
        }
    }
}
