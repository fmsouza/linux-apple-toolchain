import ArgumentParser
import Foundation
import XlessCore

extension Platform: ExpressibleByArgument {}

struct ProjectOptions: ParsableArguments {
    @Option(help: "Project directory containing xless.yml and Package.swift.")
    var project: String = "."

    @Option(help: "Tauri overlay file (type: tauri) instead of a project directory; cannot be combined with --project.")
    var config: String?

    @Option(help: "With --config: use this directory as the app source instead of the overlay's `source:`.")
    var source: String?

    @Option(help: "Target platform: ios or macos.")
    var platform: Platform

    @Option(help: "Override the build number from xless.yml (also XLESS_BUILD_NUMBER).")
    var buildNumber: String?

    func validate() throws {
        if config != nil, project != "." {
            throw ValidationError("--config cannot be combined with --project")
        }
        if config == nil, source != nil {
            throw ValidationError("--source requires --config")
        }
    }

    var configURL: URL? { config.map { URL(fileURLWithPath: $0).standardizedFileURL } }
    var projectURL: URL { URL(fileURLWithPath: project).standardizedFileURL }
}
