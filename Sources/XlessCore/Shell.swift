import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public enum Shell {
    /// Secrets never handed to child processes: builds run third-party package code (SwiftPM macros and plugins,
    /// unsandboxed on Linux), and signing/notarization get their keys through 0600 temp files instead.
    public static let scrubbedEnvironment: [String] = ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8", "XLESS_DIST_KEY", "XLESS_DEVID_KEY"]
        .flatMap { [$0, "\($0)_FILE"] }
    /// Runs `executable` (resolved via PATH) with `arguments`. Throws XlessError(stage) on non-zero exit.
    /// The child inherits this process's environment minus `scrubbedEnvironment`, plus `env` (explicit entries win;
    /// a nil value removes a variable). passthrough: stream output to the terminal instead of capturing it.
    @discardableResult
    public static func run(
        _ executable: String, _ arguments: [String],
        cwd: URL? = nil, env: [String: String?] = [:],
        stage: Stage, passthrough: Bool = false
    ) throws -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [executable] + arguments
        if let cwd { p.currentDirectoryURL = cwd }
        var environment = ProcessInfo.processInfo.environment
        for name in scrubbedEnvironment { environment[name] = nil }
        for (k, v) in env { environment[k] = v }
        p.environment = environment

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xless-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outURL = tmp.appendingPathComponent("out"), errURL = tmp.appendingPathComponent("err")
        _ = FileManager.default.createFile(atPath: outURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
        if !passthrough {
            p.standardOutput = out
            p.standardError = err
        }
        do { try p.run() } catch {
            throw XlessError(stage, "cannot start \(executable): \(error)", fix: "install \(executable) or check PATH")
        }
        p.waitUntilExit()
        try out.close()
        try err.close()
        let stdout = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        if p.terminationStatus != 0 {
            let tail = stderr.split(separator: "\n").suffix(20).joined(separator: "\n")
            throw XlessError(stage, "`\(executable) \(arguments.joined(separator: " "))` exited with \(p.terminationStatus)\(tail.isEmpty ? "" : ":\n\(tail)")",
                             fix: "see the tool output above")
        }
        return ShellResult(status: p.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
