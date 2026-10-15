import Foundation
import XlessASC
import XlessCore
import XlessTauri

struct Context {
    let project: URL
    let config: ProjectConfig
    let platform: Platform
    let paths: StagePaths
    let secrets: Secrets
    /// `--build-number` or `XLESS_BUILD_NUMBER`, when given (re-resolved on every invocation).
    let buildOverride: String?
    /// With `--config`: the parsed Tauri overlay, the source tree it points at and the work copy location.
    var overlay: TauriOverlay? = nil
    var sourceRoot: URL? = nil
    var workRoot: URL? = nil
    var tauri: ResolvedTauri? = nil

    /// The Tauri stages' view of this context; nil without `--config`.
    var tauriBuild: TauriBuildContext? {
        guard let overlay, let sourceRoot, let workRoot, let tauri else { return nil }
        return TauriBuildContext(overlay: overlay, resolved: tauri, sourceRoot: sourceRoot, workRoot: workRoot, paths: paths)
    }

    static func load(_ opts: ProjectOptions, env: [String: String] = ProcessInfo.processInfo.environment, fresh: Bool = false) async throws -> Context {
        let override = opts.buildNumber ?? env["XLESS_BUILD_NUMBER"].flatMap { $0.isEmpty ? nil : $0 }
        if let configURL = opts.configURL {
            let loc = try OverlayLocation.load(from: configURL, sourceOverride: opts.source, env: env)
            var resolved = try TauriProject.resolve(overlay: loc.overlay, source: loc.sourceRoot)
            _ = try resolved.config.platform(opts.platform)
            try await settleBuild(&resolved.config, override: override, workRoot: loc.workRoot, env: env, fresh: fresh)
            return Context(project: loc.workRoot, config: resolved.config, platform: opts.platform,
                           paths: StagePaths(project: loc.workRoot, platform: opts.platform), secrets: Secrets(env: env),
                           buildOverride: override, overlay: loc.overlay, sourceRoot: loc.sourceRoot, workRoot: loc.workRoot, tauri: resolved)
        }
        let project = opts.projectURL
        var config = try ProjectConfig.load(from: project.appendingPathComponent("xless.yml"), buildOverride: override)
        _ = try config.platform(opts.platform)
        try await settleBuild(&config, override: override, workRoot: project, env: env, fresh: fresh)
        return Context(project: project, config: config, platform: opts.platform,
                       paths: StagePaths(project: project, platform: opts.platform), secrets: Secrets(env: env),
                       buildOverride: override)
    }

    /// The run's build number: the override (a dated overlay keeps its scheme), or for `build: dated` the recorded (or, for
    /// a run that starts, freshly chosen) number. Inside the `config` stage (`DatedBuildNumber.settle`).
    private static func settleBuild(_ config: inout ProjectConfig, override: String?, workRoot: URL, env: [String: String], fresh: Bool) async throws {
        let file = StagePaths(project: workRoot, platform: .ios).root.appendingPathComponent("build-number")
        try await DatedBuildNumber.settle(&config, override: override, file: file, secrets: Secrets(env: env), fresh: fresh)
    }
}
