import Foundation
import XlessCore
import XlessTauri

/// What `xless next-build --config` (and `xless tauri next-build`) print: the build number the next run of an overlay
/// would use. `compute(version, bundleID)` is the dated App Store Connect query (`DatedBuildNumber.compute`); it is
/// called only for `build: dated`, and a fixed build is returned as it is.
public enum NextBuild {
    public typealias Compute = @Sendable (_ version: String, _ bundleID: String) async throws -> String

    /// Dispatches on the overlay's `type:`: `react-native` here, anything else as a Tauri overlay.
    public static func forOverlay(at url: URL, sourceOverride: String?, env: [String: String] = ProcessInfo.processInfo.environment,
                                  compute: Compute) async throws -> String {
        if try OverlayPaths.type(of: OverlayPaths.read(url)) == "react-native" {
            let (overlay, source, work) = try ReactNativeOverlay.load(from: url, sourceOverride: sourceOverride, env: env)
            return try await ReactNativeProject.nextBuild(overlay: overlay, source: source, work: work, compute: compute)
        }
        return try await tauri(at: url, sourceOverride: sourceOverride, env: env, compute: compute)
    }

    /// A Tauri overlay (`xless tauri next-build`): the iOS bundle ID and the version `tauri.conf.json` or the overlay gives.
    public static func tauri(at url: URL, sourceOverride: String?, env: [String: String] = ProcessInfo.processInfo.environment,
                             compute: Compute) async throws -> String {
        let loc = try OverlayLocation.load(from: url, sourceOverride: sourceOverride, env: env)
        let resolved = try TauriProject.resolve(overlay: loc.overlay, source: loc.sourceRoot)
        guard resolved.config.buildScheme == .dated else { return resolved.config.build }
        return try await compute(resolved.config.version, resolved.config.bundleID(for: .ios))
    }
}

extension ReactNativeProject {
    /// The overlay is read without its work copy (step 1 of scripts/testflight.sh has none): the version comes from the
    /// overlay's `version:`, else the app's app.json / package.json in the source; the bundle ID is the app target's
    /// `bundleIDs` entry (the one named like the scheme, or the only one).
    public static func nextBuild(overlay: ReactNativeOverlay, source: URL, work: URL, compute: NextBuild.Compute) async throws -> String {
        let resolved = try resolve(overlay: overlay, source: source, work: work)
        guard resolved.config.buildScheme == .dated else { return resolved.config.build }
        return try await compute(resolved.config.version, resolved.config.bundleID)
    }
}
