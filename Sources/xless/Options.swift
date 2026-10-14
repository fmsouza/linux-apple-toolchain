import ArgumentParser
import Foundation
import XlessCore

extension Platform: ExpressibleByArgument {}

struct ProjectOptions: ParsableArguments {
    @Option(help: "Project directory containing xless.yml and Package.swift.")
    var project: String = "."

    @Option(help: "Target platform: ios or macos.")
    var platform: Platform

    @Option(help: "Override the build number from xless.yml (also XLESS_BUILD_NUMBER).")
    var buildNumber: String?

    var projectURL: URL { URL(fileURLWithPath: project).standardizedFileURL }
}
