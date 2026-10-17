import ArgumentParser
import Foundation
import XlessASC
import XlessCore
import XlessReactNative
import XlessTauri

/// `xless next-build --config <overlay>` for any overlay type: a React Native overlay here, a Tauri one through
/// `xless tauri next-build`. scripts/testflight.sh runs it in step 1, the only container with App Store Connect
/// credentials and no build code.
struct NextBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "next-build",
        abstract: "Print the build number the next run of an overlay would use (read-only App Store Connect query; persists nothing).",
        discussion: "For `build: dated` it asks App Store Connect for the builds of the version (credentials needed); a fixed build is printed as is. A React Native overlay is read without its work copy: the version comes from the overlay's `version:` or the app's app.json / package.json in the source, the bundle ID from `bundleIDs`. scripts/testflight.sh runs it with credentials, then builds without them using XLESS_BUILD_NUMBER.")
    @Option(name: .long, help: "Overlay file (type: react-native or type: tauri).") var config: String
    @Option(name: .long, help: "Use this directory as the app source instead of the overlay's `source:`.") var source: String?

    func run() async throws {
        let url = URL(fileURLWithPath: config).standardizedFileURL
        print(try await NextBuild.forOverlay(at: url, sourceOverride: source, compute: NextBuild.datedLookup))
    }
}

extension NextBuild {
    /// `DatedBuildNumber.compute` with the process's credentials, as the `config` stage (`[config] …`, exit 10).
    static let datedLookup: Compute = { version, bundleID in
        try await withStage(.config) { try await DatedBuildNumber.compute(version: version, bundleID: bundleID, secrets: Secrets()) }
    }
}
