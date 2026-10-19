import ArgumentParser
import Foundation
import XlessCore

/// `xless docker`: a project's build in the local images (made by `xless setup`), by running the share's scripts/testflight.sh.
/// The arguments go to the script unchanged. The process is replaced (execvp), so the script's exit code is the user's and
/// its environment (the App Store Connect variables, which `Shell.run` would scrub) reaches it as the user set it.
struct DockerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "docker",
        abstract: "Build, sign and ship a project in the local xless images (see xless setup).",
        discussion: """
        Usage: xless docker [<project-dir> | --config <overlay.yml>] [testflight.sh options …] [-- xless ship args]

        Runs <share>/scripts/testflight.sh with the arguments unchanged, with XLESS_USE_DOCKER=1 unless you set it and \
        XLESS_SHARE set to the share directory. Example: xless docker MyApp --build-number 1 --to finalize
        """)

    @Argument(parsing: .allUnrecognized, help: "A project directory or --config <overlay.yml>, then testflight.sh's options.")
    var arguments: [String] = []

    func run() throws {
        let env = ProcessInfo.processInfo.environment
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let share = try XlessShare.root(env: env, executable: exe)
        let script = share.appendingPathComponent("scripts/testflight.sh").path
        guard FileManager.default.fileExists(atPath: script) else {
            throw XlessError(.sdk, "\(script) does not exist", fix: "reinstall xless (see README) or set XLESS_SHARE")
        }
        if env["XLESS_USE_DOCKER"]?.isEmpty ?? true { setenv("XLESS_USE_DOCKER", "1", 1) }
        setenv("XLESS_SHARE", share.path, 1)
        let argv = ["bash", script] + arguments
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgs.append(nil)
        execvp("bash", cArgs)
        throw XlessError(.sdk, "cannot run bash: \(String(cString: strerror(errno)))", fix: "install bash")
    }
}
