import Foundation
import XlessCore

public enum IOSBuilder {
    /// Runs `xtool dev build --configuration release` (unsigned) and copies the .app into paths.app.
    public static func build(project: URL, config: ProjectConfig, paths: StagePaths) throws -> URL {
        let ios = try config.platform(.ios)
        try XtoolManifest.write(config: config, project: project)
        try Shell.run("xtool", ["dev", "build", "--configuration", "release"], cwd: project, stage: .build, passthrough: true)
        let produced = project.appendingPathComponent("xtool/\(ios.product).app")
        guard FileManager.default.fileExists(atPath: produced.path) else {
            throw XlessError(.build, "xtool finished but \(produced.path) is missing", fix: "check that platforms.ios.product matches a library product in Package.swift")
        }
        return try Files.atomicOutput(paths.app) { try Files.copyBundle(produced, intoFreshDir: $0) }
    }
}
