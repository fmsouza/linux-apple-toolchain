import Foundation
import XlessCore

struct Context {
    let project: URL
    let config: ProjectConfig
    let platform: Platform
    let paths: StagePaths
    let secrets: Secrets
    /// `--build-number` or `XLESS_BUILD_NUMBER`, when given (re-resolved on every invocation).
    let buildOverride: String?

    static func load(_ opts: ProjectOptions, env: [String: String] = ProcessInfo.processInfo.environment) throws -> Context {
        let project = opts.projectURL
        let override = opts.buildNumber ?? env["XLESS_BUILD_NUMBER"].flatMap { $0.isEmpty ? nil : $0 }
        let config = try ProjectConfig.load(from: project.appendingPathComponent("xless.yml"), buildOverride: override)
        _ = try config.platform(opts.platform)
        return Context(project: project, config: config, platform: opts.platform,
                       paths: StagePaths(project: project, platform: opts.platform), secrets: Secrets(env: env),
                       buildOverride: override)
    }
}
