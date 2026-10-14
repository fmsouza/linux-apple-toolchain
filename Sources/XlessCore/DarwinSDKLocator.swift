import Foundation

/// Where `xtool sdk install` puts the Darwin Swift SDK (xtool Sources/XKit/.../DarwinSDK.swift).
public enum DarwinSDKLocator {
    public static func bundle(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: "\(xdg)/swiftpm/swift-sdks/darwin.artifactbundle")
        }
        return URL(fileURLWithPath: "\(env["HOME"] ?? "~")/.swiftpm/swift-sdks/darwin.artifactbundle")
    }
}
